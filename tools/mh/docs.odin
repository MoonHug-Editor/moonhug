package mh

// `mh docs`: build the documentation site into builds/docs, and with --open
// open it. The site is read from the file system, no server involved.
//
// Hugo's config is tools/docs/hugo.toml. Each plugin keeps its pages in its
// own docs/ folder, and Hugo has no glob for mounts, so one mount per plugin
// is written into a second config file passed beside the first. The prebuild
// runs first so the generated reference pages are current.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

DOCS_CONFIG :: "tools/docs/hugo.toml"
DOCS_MOUNTS :: "builds/docs-mounts.toml"
DOCS_INDEX  :: "builds/docs/index.html"
DOCS_PKG_DIR :: "docs/reference/packages"
DOCS_HOME_DIR :: "builds/docs-home"
// The External Tools user setting, read for its source_url field
// (core.user_settings_file names it).
DOCS_USER_TOOLS :: "moonhug/UserSettings/external_tools.json"
// Not Hugo's 1313, so a docs server and any other Hugo project on the
// machine do not fight over a port. Hugo moves on if this one is busy.
DOCS_PORT :: "7272"

cmd_docs :: proc(args: []string) -> int {
	if !prebuild(docs = true) do return 1
	if !docs_write_plugin_mounts() do return 1
	if !docs_write_package_pages() do return 1
	// Hugo never removes files from publishDir on its own, and its clean flag
	// left a whole folder behind after the site's layout changed, so the
	// output is removed outright. It is a build artifact, nothing lives there.
	os.remove_all("builds/docs")
	if code := run("hugo", "--source", ".", "--config", DOCS_CONFIG + "," + DOCS_MOUNTS); code != 0 {
		fmt.eprintfln("mh: hugo failed (exit %d)", code)
		return code
	}
	if !docs_strip_integrity() do return 1
	fmt.printfln("mh: docs at %s", DOCS_INDEX)
	for a in args {
		if a != "--open" do continue
		// Served rather than opened as a file: search in every theme loads its
		// index with fetch(), which browsers refuse on a file:// page, and over
		// http nothing needs patching. Reading without search is the file:
		// double-click builds/docs/index.html.
		// Rendered to memory: by default the server writes into publishDir,
		// the same folder the build above produced, and a running server and
		// a later `mh docs` then overwrite each other's pages.
		// The config's baseURL is '/' for file:// reading, which makes the
		// server announce itself as "//localhost:1313" and the browser opener
		// treat that as a path. The server gets a URL with a scheme and no
		// port: Hugo appends whichever port it actually binds, so a busy 1313
		// does not leave the links pointing at the wrong one.
		return run("hugo", "server", "--source", ".", "--config", DOCS_CONFIG + "," + DOCS_MOUNTS, "--baseURL", "http://localhost/", "--port", DOCS_PORT, "--renderToMemory", "--openBrowser")
	}
	return 0
}

// The URL template every source location in the reference pages links to,
// with {file} and {line} to fill in. It is the `source_url` field of the
// External Tools user setting when set. Otherwise it is the file on GitHub
// on the current branch, from the origin remote: a branch link works once
// the branch is pushed, where a commit link is dead until that commit is.
// Without a GitHub remote it is the file on disk, with no line. Resolved
// once per run.
docs_source_url :: proc() -> string {
	@(static) resolved: string
	@(static) done: bool
	if done do return resolved
	done = true
	if data, err := os.read_entire_file(DOCS_USER_TOOLS, context.temp_allocator); err == nil {
		if t := strings.trim_space(_json_string_field(string(data), "source_url")); t != "" {
			resolved = strings.clone(t)
			return resolved
		}
	}
	resolved = "file://{file}"
	remote, rcode := run_capture("git", "remote", "get-url", "origin")
	defer delete(remote)
	branch, bcode := run_capture("git", "rev-parse", "--abbrev-ref", "HEAD")
	defer delete(branch)
	if rcode != 0 || bcode != 0 do return resolved
	ref := strings.trim_space(branch)
	// A detached checkout has no branch name, the commit is all there is.
	if ref == "HEAD" {
		sha, scode := run_capture("git", "rev-parse", "HEAD")
		defer delete(sha)
		if scode != 0 do return resolved
		ref = strings.clone(strings.trim_space(sha), context.temp_allocator)
	}
	repo := strings.trim_space(remote)
	switch {
	case strings.has_prefix(repo, "git@github.com:"):    repo = repo[len("git@github.com:"):]
	case strings.has_prefix(repo, "https://github.com/"): repo = repo[len("https://github.com/"):]
	case strings.has_prefix(repo, "ssh://git@github.com/"): repo = repo[len("ssh://git@github.com/"):]
	case: return resolved
	}
	repo = strings.trim_suffix(strings.trim_suffix(repo, "/"), ".git")
	// Concatenated, not formatted: fmt reads {file} as a format argument.
	resolved = strings.concatenate({"https://github.com/", repo, "/blob/", ref, "/{file}#L{line}"})
	return resolved
}

// docs_source_href fills a docs_source_url template for a repo-relative
// path. {file} is the relative path for GitHub and the absolute path for any
// other template, since an editor URL needs the absolute one.
// This tool imports nothing from the moonhug collection, so this is the
// same rule as gen_core.SourceHref: {file} is the real path, the packages
// link resolved, repo-relative for GitHub and absolute for an editor URL.
docs_source_href :: proc(rel_path: string, line: int) -> string {
	template := docs_source_url()
	file := docs_source_real_path(rel_path)
	if !strings.has_prefix(template, "https://github.com/") {
		cwd, _ := os.get_working_directory(context.temp_allocator)
		file = fmt.tprintf("%s/%s", cwd, file)
	}
	href, _ := strings.replace_all(template, "{file}", file, context.temp_allocator)
	href, _ = strings.replace_all(href, "{line}", fmt.tprintf("%d", line), context.temp_allocator)
	return href
}

// A plugin's moonhug/packages/<name> link replaced by the folder it points
// to: a link is a file on GitHub, not a folder. Temp-allocated.
docs_source_real_path :: proc(rel_path: string) -> string {
	PACKAGES :: "moonhug/packages/"
	if !strings.has_prefix(rel_path, PACKAGES) do return rel_path
	rest := rel_path[len(PACKAGES):]
	slash := strings.index_byte(rest, '/')
	if slash <= 0 do return rel_path
	link := rel_path[:len(PACKAGES) + slash]
	target, err := os.read_link(link, context.temp_allocator)
	if err != nil do return rel_path
	context.allocator = context.temp_allocator // filepath.dir and clean take no allocator
	real, _ := filepath.join({filepath.dir(link), target})
	cleaned, _ := filepath.clean(strings.concatenate({real, rest[slash:]}))
	return cleaned
}

// Removes integrity="…" and crossorigin="…" from every built page. Browsers
// check subresource integrity through CORS, and a file:// page has no origin
// to pass it, so a stylesheet or script carrying the attribute is refused
// and the site opens unstyled. The attributes protect against a tampered
// CDN, which a local file read does not have. Theme-independent, so a theme
// change does not reopen this.
docs_strip_integrity :: proc() -> bool {
	return _strip_in_dir("builds/docs")
}

@(private = "file")
_strip_in_dir :: proc(dir: string) -> bool {
	handle, oerr := os.open(dir)
	if oerr != nil do return true
	defer os.close(handle)
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil do return true
	for e in entries {
		path := fmt.tprintf("%s/%s", dir, e.name)
		if e.type == .Directory {
			if !_strip_in_dir(path) do return false
			continue
		}
		if !strings.has_suffix(e.name, ".html") do continue
		data, derr := os.read_entire_file(path, context.temp_allocator)
		if derr != nil do continue
		out := _strip_attr(string(data), ` integrity="`)
		out = _strip_attr(out, ` crossorigin="`)
		if len(out) == len(data) do continue
		if err := os.write_entire_file(path, transmute([]byte)out); err != nil {
			fmt.eprintfln("mh: cannot rewrite %s: %v", path, err)
			return false
		}
	}
	return true
}

// Drops every ` name="value"` occurrence of one attribute.
@(private = "file")
_strip_attr :: proc(html: string, prefix: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	rest := html
	for {
		i := strings.index(rest, prefix)
		if i < 0 {
			strings.write_string(&b, rest)
			break
		}
		strings.write_string(&b, rest[:i])
		after := rest[i + len(prefix):]
		q := strings.index_byte(after, '"')
		if q < 0 {
			strings.write_string(&b, rest[i:])
			break
		}
		rest = after[q + 1:]
	}
	return strings.to_string(b)
}

// Every content mount, in one file: the hand-written tree, the landing pages,
// and one entry per plugins/<name>/docs folder in name order so the file is
// identical between runs. ALL of them live here because a later config file
// replaces an earlier file's [[module.mounts]] array rather than adding to it,
// so a split list would silently drop whichever half came first.
docs_write_plugin_mounts :: proc() -> bool {
	handle, oerr := os.open("plugins")
	if oerr != nil {
		fmt.eprintfln("mh: cannot open plugins/: %v", oerr)
		return false
	}
	defer os.close(handle)
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil {
		fmt.eprintfln("mh: cannot read plugins/: %v", rerr)
		return false
	}
	names := make([dynamic]string, context.temp_allocator)
	for e in entries {
		if e.type != .Directory do continue
		if os.is_dir(fmt.tprintf("plugins/%s/docs", e.name)) do append(&names, e.name)
	}
	slice.sort(names[:])

	b := strings.builder_make(context.temp_allocator)
	// The site follows the repo one level down: docs/general is /general,
	// docs/core is /core, a plugin's pages are /plugins/<name>. The README's
	// repo-path links are rewritten to match in docs_write_home.
	strings.write_string(&b, "# Written by `mh docs`. Not committed, not edited.\n")
	for sec in ([]string{"general", "core", "reference"}) {
		fmt.sbprintf(&b, "[[module.mounts]]\nsource = 'docs/%s'\ntarget = 'content/%s'\n", sec, sec)
	}
	strings.write_string(&b, "[[module.mounts]]\nsource = 'builds/docs-home'\ntarget = 'content'\n")
	// The README's images, at the path the README uses, so the home page
	// shows them without the README changing.
	strings.write_string(&b, "[[module.mounts]]\nsource = 'readme_files'\ntarget = 'static/readme_files'\n")
	for n in names {
		fmt.sbprintf(&b, "[[module.mounts]]\nsource = 'plugins/%s/docs'\ntarget = 'content/plugins/%s'\n", n, n)
	}
	if !docs_write_home(names[:]) do return false
	os.make_directory("builds")
	if err := os.write_entire_file(DOCS_MOUNTS, transmute([]byte)strings.to_string(b)); err != nil {
		fmt.eprintfln("mh: cannot write %s: %v", DOCS_MOUNTS, err)
		return false
	}
	return true
}

// The README is the home page. It is copied rather than mounted directly so
// it can carry frontmatter: an empty title, because the README has its own
// heading and the theme prints the title as one. Its links are repo paths
// like every page's, which the site's link hook translates
// (tools/docs/layouts/_markup/render-link.html).
docs_write_home :: proc(plugins: []string) -> bool {
	data, rerr := os.read_entire_file("README.md", context.temp_allocator)
	if rerr != nil {
		fmt.eprintfln("mh: cannot read README.md: %v", rerr)
		return false
	}
	body := string(data)
	// LICENSE is a repo file with no page, so the README's link to it would be
	// dead on the site. The site gets a License page (written below), and the
	// site's copy of the README links there. GitHub keeps the plain link.
	body, _ = strings.replace_all(body, "](LICENSE)", "](docs/general/License.md)", context.temp_allocator)
	// Rebuilt whole: a page this stops writing must not survive from an
	// earlier build, it would still be mounted into the site.
	os.remove_all(DOCS_HOME_DIR)
	os.make_directory(DOCS_HOME_DIR)
	page := strings.concatenate({"---\ntitle: \"\"\ntype: \"docs\"\n---\n\n", body}, context.temp_allocator)
	if err := os.write_entire_file(DOCS_HOME_DIR + "/_index.md", transmute([]byte)page); err != nil {
		fmt.eprintfln("mh: cannot write %s/_index.md: %v", DOCS_HOME_DIR, err)
		return false
	}
	// The License page the README's link points at, under General beside the
	// third-party notices.
	license, lerr := os.read_entire_file("LICENSE", context.temp_allocator)
	if lerr != nil {
		fmt.eprintfln("mh: cannot read LICENSE: %v", lerr)
		return false
	}
	os.make_directory(fmt.tprintf("%s/general", DOCS_HOME_DIR))
	lp := strings.concatenate({"---\ntitle: \"License\"\ndescription: \"The license MoonHug is distributed under\"\nweight: 1004\ntags: [\"contributing\"]\n---\n\n", string(license)}, context.temp_allocator)
	if err := os.write_entire_file(fmt.tprintf("%s/general/License.md", DOCS_HOME_DIR), transmute([]byte)lp); err != nil {
		fmt.eprintfln("mh: cannot write the License page: %v", err)
		return false
	}
	// The Plugins section index. The repo has no plugins/docs folder to hold
	// one, the section exists only on the site, so it is written here.
	os.make_directory(fmt.tprintf("%s/plugins", DOCS_HOME_DIR))
	sec := "---\ntitle: \"Plugins\"\ndescription: \"Documentation that ships with each plugin\"\nweight: 30\n---\n\nEach plugin keeps its pages in its own `docs/` folder and they are collected here at build time. The plugins model itself is described in [Plugins](/docs/core/Plugins.md), and how this site is put together in [Documentation](/docs/general/Documentation.md).\n"
	if err := os.write_entire_file(fmt.tprintf("%s/plugins/_index.md", DOCS_HOME_DIR), transmute([]byte)sec); err != nil {
		fmt.eprintfln("mh: cannot write plugins/_index.md: %v", err)
		return false
	}
	// A landing page per plugin, so the sidebar has a titled, clickable
	// section. The description comes from the manifest when it has one.
	for n in plugins {
		desc := fmt.tprintf("Pages of the %s plugin", n)
		if m, merr := os.read_entire_file(fmt.tprintf("plugins/%s/mh_plugin.json", n), context.temp_allocator); merr == nil {
			if d := _json_string_field(string(m), "description"); d != "" do desc = d
		}
		dir := fmt.tprintf("%s/plugins/%s", DOCS_HOME_DIR, n)
		os.make_directory(dir)
		ip := fmt.tprintf("---\ntitle: \"%s\"\ndescription: \"%s\"\n---\n", n, desc)
		if err := os.write_entire_file(fmt.tprintf("%s/_index.md", dir), transmute([]byte)ip); err != nil {
			fmt.eprintfln("mh: cannot write %s/_index.md: %v", dir, err)
			return false
		}
	}
	return true
}

// The string value of one top-level field in a small flat JSON object, "" when
// absent or empty. Enough for the manifest and the External Tools user setting,
// which this tool does not otherwise parse.
@(private = "file")
_json_string_field :: proc(json: string, field: string) -> string {
	key := fmt.tprintf("\"%s\"", field)
	i := strings.index(json, key)
	if i < 0 do return ""
	rest := json[i + len(key):]
	c := strings.index_byte(rest, ':')
	if c < 0 do return ""
	rest = strings.trim_left_space(rest[c + 1:])
	if len(rest) == 0 || rest[0] != '"' do return ""
	rest = rest[1:]
	e := strings.index_byte(rest, '"')
	if e < 0 do return ""
	return rest[:e]
}
