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
import "core:slice"
import "core:strings"

DOCS_CONFIG :: "tools/docs/hugo.toml"
DOCS_MOUNTS :: "builds/docs-mounts.toml"
DOCS_INDEX  :: "builds/docs/index.html"
DOCS_PKG_DIR :: "docs/reference/packages"
DOCS_HOME_DIR :: "builds/docs-home"
// Not Hugo's 1313, so a docs server and any other Hugo project on the
// machine do not fight over a port. Hugo moves on if this one is busy.
DOCS_PORT :: "7272"

cmd_docs :: proc(args: []string) -> int {
	if !prebuild() do return 1
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
		// The config's baseURL is '/' for file:// reading, which makes the
		// server announce itself as "//localhost:1313" and the browser opener
		// treat that as a path. The server gets a URL with a scheme and no
		// port: Hugo appends whichever port it actually binds, so a busy 1313
		// does not leave the links pointing at the wrong one.
		return run("hugo", "server", "--source", ".", "--config", DOCS_CONFIG + "," + DOCS_MOUNTS, "--baseURL", "http://localhost/", "--port", DOCS_PORT, "--openBrowser")
	}
	return 0
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

// One page per package under the engine and editor trees, holding what
// `odin doc` says about it: every public declaration with its comment. The
// prebuild's docs_gen writes the attribute pages beside these, so the whole
// reference section is built, not written. tests/ folders are not packages a
// plugin imports, and external/ is not ours.
//
// One `odin doc` run per package, each a parse and check of that package and
// everything it imports, so this is the slow part of `mh docs`.
docs_write_package_pages :: proc() -> bool {
	pkgs := make([dynamic]string, context.temp_allocator)
	for root in ([]string{"moonhug/engine", "moonhug/editor", "moonhug/engine_editor"}) {
		_collect_packages(root, &pkgs)
	}
	slice.sort(pkgs[:])
	os.make_directory(DOCS_PKG_DIR)

	index := strings.builder_make(context.temp_allocator)
	strings.write_string(&index, "---\ntitle: \"Packages\"\ndescription: \"Every public declaration of each engine and editor package, with its comment\"\nweight: 1000\n---\n\n")
	strings.write_string(&index, "Generated by `mh docs` from `odin doc`. A plugin reaches these through the `moonhug:` collection.\n\n")

	for p, i in pkgs {
		import_path := fmt.tprintf("moonhug:%s", p[len("moonhug/"):])
		slug, _ := strings.replace_all(p[len("moonhug/"):], "/", "_", context.temp_allocator)
		// Text output goes to stdout only: `-out:` applies to -doc-format.
		data, code := run_capture("odin", "doc", p, "-collection:moonhug=moonhug", "-ignore-unknown-attributes")
		defer delete(data)
		if code != 0 {
			fmt.eprintfln("mh: odin doc failed for %s (exit %d)", p, code)
			return false
		}
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, "---\ntitle: \"%s\"\ndescription: \"Public declarations of %s with their comments\"\nweight: %d\ntags: [\"reference\", \"package\"]\n---\n\n", import_path, import_path, (i + 1) * 10)
		// Four backticks, so a comment that itself contains a three-backtick
		// fence cannot end the block early.
		strings.write_string(&b, "````text\n")
		strings.write_string(&b, data)
		strings.write_string(&b, "\n````\n")
		if err := os.write_entire_file(fmt.tprintf("%s/%s.md", DOCS_PKG_DIR, slug), transmute([]byte)strings.to_string(b)); err != nil {
			fmt.eprintfln("mh: cannot write package page for %s: %v", p, err)
			return false
		}
		fmt.sbprintf(&index, "- [%s](%s.md)\n", import_path, slug)
	}
	if err := os.write_entire_file(DOCS_PKG_DIR + "/_index.md", transmute([]byte)strings.to_string(index)); err != nil {
		fmt.eprintfln("mh: cannot write %s/_index.md: %v", DOCS_PKG_DIR, err)
		return false
	}
	return true
}

// Every directory under `dir` holding at least one .odin file, recursively.
@(private = "file")
_collect_packages :: proc(dir: string, out: ^[dynamic]string) {
	handle, oerr := os.open(dir)
	if oerr != nil do return
	defer os.close(handle)
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil do return
	has_odin := false
	for e in entries {
		if e.type == .Directory {
			if e.name == "tests" || e.name == "external" || strings.has_prefix(e.name, ".") do continue
			_collect_packages(fmt.tprintf("%s/%s", dir, e.name), out)
		} else if strings.has_suffix(e.name, ".odin") {
			has_odin = true
		}
	}
	if has_odin do append(out, strings.clone(dir, context.temp_allocator))
}

// The README is the home page. It is copied rather than mounted directly so
// it can carry frontmatter: an empty title, because the README has its own
// heading and the theme prints the title as one. Its links are repo paths,
// rewritten to the site's: docs/<section>/ loses the docs/ prefix and
// plugins/<name>/docs/ loses the docs/ folder.
docs_write_home :: proc(plugins: []string) -> bool {
	data, rerr := os.read_entire_file("README.md", context.temp_allocator)
	if rerr != nil {
		fmt.eprintfln("mh: cannot read README.md: %v", rerr)
		return false
	}
	body := string(data)
	for n in plugins {
		body, _ = strings.replace_all(body, fmt.tprintf("plugins/%s/docs/", n), fmt.tprintf("plugins/%s/", n), context.temp_allocator)
	}
	for sec in ([]string{"general", "core", "reference"}) {
		body, _ = strings.replace_all(body, fmt.tprintf("docs/%s/", sec), fmt.tprintf("%s/", sec), context.temp_allocator)
	}
	// Rebuilt whole: a page this stops writing must not survive from an
	// earlier build, it would still be mounted into the site.
	os.remove_all(DOCS_HOME_DIR)
	os.make_directory(DOCS_HOME_DIR)
	page := strings.concatenate({"---\ntitle: \"\"\ntype: \"docs\"\n---\n\n", body}, context.temp_allocator)
	if err := os.write_entire_file(DOCS_HOME_DIR + "/_index.md", transmute([]byte)page); err != nil {
		fmt.eprintfln("mh: cannot write %s/_index.md: %v", DOCS_HOME_DIR, err)
		return false
	}
	// The Plugins section index. The repo has no plugins/docs folder to hold
	// one, the section exists only on the site, so it is written here.
	os.make_directory(fmt.tprintf("%s/plugins", DOCS_HOME_DIR))
	sec := "---\ntitle: \"Plugins\"\ndescription: \"Documentation that ships with each plugin\"\nweight: 30\n---\n\nEach plugin keeps its pages in its own `docs/` folder and they are collected here at build time. The plugins model itself is described in [Plugins](../core/Plugins.md), and how this site is put together in [Documentation](../general/Documentation.md).\n"
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
// absent or empty. Enough for the manifest, which this tool does not otherwise parse.
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
