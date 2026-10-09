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
	// Served or read from disk decides what a source link opens, so it is
	// known before the pages are generated.
	docs_serving = slice.contains(args, "--open")
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

// True for `mh docs --open`: the site is served over http, where a page can
// fetch a source file, so the source viewer works and the raw files are
// mounted. Read from disk nothing can be fetched.
docs_serving: bool

// The folders the viewer can show, mounted raw under /source when serving,
// .odin files only: the host, the shell, the prebuild, the tests, every
// plugin by its real path, and this tool.
DOCS_SOURCE_ROOTS :: []string{"moonhug/host", "moonhug/editor", "moonhug/prebuild", "moonhug/registration", "moonhug/tests", "plugins", "tools/mh"}

// The URL template every source location in the reference pages links to,
// with {file} and {line} to fill in. It is the `source_url` field of the
// External Tools user setting when set, an editor's URL scheme. Otherwise,
// served, it is the site's source viewer (docs_write_viewer), which reads
// the file as it is on disk when the link is clicked. Read from disk it is
// the file itself. Resolved once per run.
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
	// Site-absolute, which relativeURLs rewrites per page.
	resolved = "/source.html?file={file}&line={line}" if docs_serving else "file://{file}"
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
	if docs_source_wants_absolute(template) {
		cwd, _ := os.get_working_directory(context.temp_allocator)
		file = fmt.tprintf("%s/%s", cwd, file)
	}
	href, _ := strings.replace_all(template, "{file}", file, context.temp_allocator)
	href, _ = strings.replace_all(href, "{line}", fmt.tprintf("%d", line), context.temp_allocator)
	return href
}

// An editor's URL scheme (zed://, vscode://, file://) wants the absolute
// path, a web URL (GitHub) and the site's own pages the repo-relative one.
docs_source_wants_absolute :: proc(template: string) -> bool {
	return strings.contains(template, "://") && !strings.has_prefix(template, "https://") && !strings.has_prefix(template, "http://")
}

// A plugin's moonhug/packages/<name> link replaced by the folder it points
// to: a link is a file on GitHub, not a folder. Temp-allocated.
docs_source_real_path :: proc(rel_path: string) -> string {
	PACKAGES :: "moonhug/packages/"
	context.allocator = context.temp_allocator // filepath.dir and clean take no allocator
	path := rel_path
	// A sample is a link to a folder inside another plugin's link
	// (timeline_sample -> animation/samples/timeline_sample), so links are
	// followed until the path leaves moonhug/packages. The bound stops a cycle.
	for _ in 0 ..< 8 {
		if !strings.has_prefix(path, PACKAGES) do break
		rest := path[len(PACKAGES):]
		slash := strings.index_byte(rest, '/')
		if slash <= 0 do break
		link := path[:len(PACKAGES) + slash]
		target, err := os.read_link(link, context.temp_allocator)
		if err != nil do break
		real, _ := filepath.join({filepath.dir(link), target})
		path, _ = filepath.clean(strings.concatenate({real, rest[slash:]}))
	}
	return path
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
	// The raw source files the viewer fetches, served only: a static mount
	// in a disk build would copy them into the output.
	if docs_serving {
		for root in DOCS_SOURCE_ROOTS {
			if !os.is_dir(root) do continue
			// The folders match too, or the walk prunes them before any file.
			fmt.sbprintf(&b, "[[module.mounts]]\nsource = '%s'\ntarget = 'static/source/%s'\nfiles = ['**/', '**.odin']\n", root, root)
		}
	}
	if !docs_write_home(names[:]) do return false
	if !docs_write_viewer() do return false
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


// The source viewer page, /source.html?file=<repo path>&line=<n>: fetches the
// file from the raw mount and shows it with line numbers, a small Odin
// tokenizer coloring it with the site's syntax classes, scrolled to the
// line. It works served (the mount exists and fetch is allowed) and explains
// itself otherwise. The page is markdown: each HTML block starts after a
// blank line and holds none inside, or the renderer turns its tail into
// paragraphs. The script block ends at the first line that contains a
// closing pre, style or textarea tag, so the script writes "<\/pre>".
docs_write_viewer :: proc() -> bool {
	path := fmt.tprintf("%s/source.md", DOCS_HOME_DIR)
	if err := os.write_entire_file(path, transmute([]byte)string(DOCS_VIEWER_PAGE)); err != nil {
		fmt.eprintfln("mh: cannot write %s: %v", path, err)
		return false
	}
	return true
}

DOCS_VIEWER_PAGE :: `---
title: "Source"
sidebar:
  exclude: true
excludeSearch: true
---

<style>
  .mh-src { font-size: 0.85rem; line-height: 1.45; }
  .mh-src .mh-path { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; margin-bottom: 0.75rem; opacity: 0.8; }
  .mh-src pre { padding: 0.5rem 0; overflow-x: auto; }
  .mh-src pre code { display: block; width: max-content; min-width: 100%; }
  .mh-src .line { padding: 0 0.75rem; }
  .mh-src .line:target, .mh-src .line.hl { background: rgba(255, 200, 0, 0.18); outline: 1px solid rgba(255, 200, 0, 0.5); }
  .mh-src .ln { display: inline-block; width: 4ch; margin-right: 1.5ch; text-align: right; opacity: 0.4; user-select: none; }
  .mh-src .ln a { color: inherit; text-decoration: none; }
  .mh-src .msg { padding: 1rem; border: 1px solid rgba(128,128,128,0.4); border-radius: 6px; }
</style>

<div class="mh-src">
  <div class="mh-path" id="mh-path"></div>
  <div id="mh-body"><div class="msg">Loading…</div></div>
</div>

<script>
(function () {
  var params = new URLSearchParams(location.search);
  var file = params.get("file") || "";
  var line = parseInt(params.get("line") || "0", 10);
  var pathEl = document.getElementById("mh-path");
  var bodyEl = document.getElementById("mh-body");
  pathEl.textContent = file;
  document.title = (file.split("/").pop() || "Source") + " – MoonHug";
  if (!file) { bodyEl.innerHTML = '<div class="msg">No file given.</div>'; return; }
  var KEYWORDS = new Set(("package import foreign proc struct union enum bit_set bit_field map dynamic matrix if else when for in not_in do switch case break continue fallthrough return defer using where or_else or_return or_break or_continue cast transmute auto_cast distinct context typeid asm").split(" "));
  var CONSTANTS = new Set(["nil", "true", "false", "---"]);
  var TYPES = new Set(("int uint uintptr i8 i16 i32 i64 i128 u8 u16 u32 u64 u128 f16 f32 f64 bool b8 b16 b32 b64 string cstring rune rawptr any byte complex64 complex128 quaternion128 quaternion256 i16le i32le i64le u16le u32le u64le i16be i32be i64be u16be u32be u64be").split(" "));
  function esc(s) { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }
  // A token that spans lines (a block comment, a raw string) is closed and
  // reopened at each newline, so every line holds whole spans.
  function span(cls, text) {
    if (!cls) return esc(text);
    return text.split("\n").map(function (p) { return '<span class="' + cls + '">' + esc(p) + "</span>"; }).join("\n");
  }
  // Tokens to Chroma classes, so the site's syntax theme colors them in
  // light and dark: c comment, s string, m number, k keyword, kt type,
  // kc constant, nd attribute, cp directive, nf declared or called name.
  function highlight(src) {
    var out = [], i = 0, n = src.length;
    var ident = /[A-Za-z_][A-Za-z0-9_]*/y;
    var number = /0[xXbBoOdDzZ][0-9A-Fa-f_]+|\d[\d_]*(\.\d[\d_]*)?([eE][+-]?\d+)?[ij]?/y;
    while (i < n) {
      var c = src[i], d = src[i + 1];
      if (c === "/" && d === "/") {
        var e = src.indexOf("\n", i); if (e < 0) e = n;
        out.push(span("c", src.slice(i, e))); i = e; continue;
      }
      if (c === "/" && d === "*") {
        var depth = 0, j = i;
        do {
          if (src.startsWith("/*", j)) { depth++; j += 2; }
          else if (src.startsWith("*/", j)) { depth--; j += 2; }
          else j++;
        } while (depth > 0 && j < n);
        out.push(span("c", src.slice(i, j))); i = j; continue;
      }
      if (c === '"' || c === "'" || c === "` + "`" + `") {
        var j = i + 1;
        while (j < n && src[j] !== c) { if (c !== "` + "`" + `" && src[j] === "\\") j++; if (src[j] === "\n" && c !== "` + "`" + `") break; j++; }
        j = Math.min(j + 1, n);
        out.push(span("s", src.slice(i, j))); i = j; continue;
      }
      if (c === "@") {
        var j = i + 1;
        // The arguments of @(...) are tokenized as code, so their strings and
        // numbers keep their own colors.
        if (src[j] === "(") j++;
        else { ident.lastIndex = j; var m = ident.exec(src); if (m) j = ident.lastIndex; }
        out.push(span("nd", src.slice(i, j))); i = j; continue;
      }
      if (c === "#") {
        ident.lastIndex = i + 1; var m = ident.exec(src);
        var j = m ? ident.lastIndex : i + 1;
        out.push(span("cp", src.slice(i, j))); i = j; continue;
      }
      if (/[0-9]/.test(c)) {
        number.lastIndex = i; var m = number.exec(src);
        if (m) { out.push(span("m", m[0])); i = number.lastIndex; continue; }
      }
      if (/[A-Za-z_]/.test(c)) {
        ident.lastIndex = i; var m = ident.exec(src); var w = m[0]; var j = ident.lastIndex;
        var cls = "";
        if (KEYWORDS.has(w)) cls = "k";
        else if (CONSTANTS.has(w)) cls = "kc";
        else if (TYPES.has(w)) cls = "kt";
        else {
          var rest = src.slice(j, j + 4);
          if (/^\s*::/.test(rest) || src[j] === "(") cls = "nf";
        }
        out.push(span(cls, w)); i = j; continue;
      }
      if (c === "-" && src.startsWith("---", i)) { out.push(span("kc", "---")); i += 3; continue; }
      out.push(esc(c)); i++;
    }
    return out.join("");
  }
  fetch("source/" + file).then(function (r) {
    if (!r.ok) throw new Error(r.status + " " + r.statusText);
    return r.text();
  }).then(function (text) {
    var lines = highlight(text).split("\n");
    if (lines.length && lines[lines.length - 1] === "") lines.pop();
    // The markup Chroma writes: the theme makes each line a flex row, so
    // the code sits in its own .cl item, where the newline and the
    // indentation survive and tab stops start at the code, not the number.
    var html = lines.map(function (code, idx) {
      var no = idx + 1;
      return '<span class="line' + (no === line ? " hl" : "") + '" id="L-' + no + '"><span class="ln"><a href="#L-' + no + '">' + no + '</a></span><span class="cl">' + code + "\n</span></span>";
    }).join("");
    bodyEl.innerHTML = '<div class="highlight"><pre class="chroma"><code>' + html + "</code><\/pre></div>";
    var target = document.getElementById("L-" + line);
    if (target) target.scrollIntoView({ block: "center" });
  }).catch(function (err) {
    bodyEl.innerHTML = '<div class="msg">Cannot read <code>' + esc(file) + "</code> (" + esc(String(err.message || err)) + "). The viewer reads files over http: run <code>make docs OPEN=1</code>, or set <code>source_url</code> in Settings &gt; External Tools to open files in your editor.</div>";
  });
})();
</script>
`
