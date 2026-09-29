package gen_facts

// Why a plugin needs another (docs/Plugins.md, "Plugin manifest"), from the
// source on disk: an import (plugin_walk) or a guid in its assets or code
// that another plugin owns. `mh deps` writes the result into the manifests,
// plugin_types_gen turns it into the editor's dependency table.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// What a guid belongs to: a plugin's asset (from its .meta) or type.
Plugin_Owner :: struct {
	pkg:  string,
	what: string, // a type name or an asset path
	dir:  string, // the declaring folder, for a type
	type: bool,
}

// The guids every package owns: asset guids from .meta files, type guids from
// @(typ_guid) declarations. A plugin's samples/ belong to the samples. Strings
// on context.allocator.
plugin_owners :: proc(pkgs: []Plugin_Folder) -> map[string]Plugin_Owner {
	owners := make(map[string]Plugin_Owner)
	for p in pkgs {
		files := make([dynamic]string, context.temp_allocator)
		plugin_files(p.dir, {"samples", "tests", "gen"}, &files)
		for f in files {
			if strings.has_suffix(f, ".meta") {
				data, err := os.read_entire_file(f, context.temp_allocator)
				if err != nil do continue
				ids := make([dynamic]string, context.temp_allocator)
				_scan_meta_guids(string(data), &ids)
				asset := strings.clone(f[len(p.dir) + 1:len(f) - len(".meta")])
				for id in ids do if id not_in owners do owners[strings.clone(id)] = Plugin_Owner{pkg = strings.clone(p.name), what = asset}
			} else if strings.has_suffix(f, ".odin") && !strings.has_suffix(f, "_generated.odin") {
				data, err := os.read_entire_file(f, context.temp_allocator)
				if err != nil do continue
				dir := f[:strings.last_index_byte(f, '/')]
				decls := make([dynamic]Plugin_Type_Decl, context.temp_allocator)
				plugin_scan_typ_guids(string(data), p.name, dir, &decls)
				for d in decls do owners[strings.clone(d.guid)] = Plugin_Owner{pkg = strings.clone(d.pkg), what = strings.clone(d.name), dir = strings.clone(d.dir), type = true}
			}
		}
	}
	return owners
}

// The guids a .meta owns: the values of its "guid" keys (the asset's, and a
// sub-asset's, a model clip's). Other uuids in it are not the asset's: the
// settings' __type_guid names an engine type.
@(private = "file")
_scan_meta_guids :: proc(src: string, out: ^[dynamic]string) {
	KEY :: "\"guid\""
	rest := src
	for {
		at := strings.index(rest, KEY)
		if at < 0 do break
		rest = rest[at + len(KEY):]
		ids := make([dynamic]string, context.temp_allocator)
		plugin_scan_uuids(rest[:min(len(rest), 48)], &ids)
		if len(ids) > 0 do append(out, ids[0])
	}
}

// A text file's contents, or ok=false for a binary or oversized one (temp).
// Sniffs the first 8 KB before reading the rest: a texture or an audio file
// costs one small read, not its size, so the scan grows with the text in
// the tree, not with the assets.
plugin_read_text :: proc(path: string) -> (string, bool) {
	MAX :: 64 * 1024 * 1024
	info, serr := os.stat(path, context.temp_allocator)
	if serr != nil || info.size > MAX do return "", false
	f, oerr := os.open(path)
	if oerr != nil do return "", false
	defer os.close(f)
	head: [8192]u8
	n, rerr := os.read(f, head[:])
	if rerr != nil || slice.contains(head[:n], 0) do return "", false
	data := make([]u8, info.size, context.temp_allocator)
	copy(data, head[:n])
	if int(info.size) > n {
		if _, err := os.read_at_least(f, data[n:], int(info.size) - n); err != nil do return "", false
	}
	return string(data), true
}

// The plugins, other than `owner`, a folder's own files import: what a type
// declared there needs beyond its plugin (temp).
plugin_folder_needs :: proc(dir, owner: string) -> [dynamic]string {
	out := make([dynamic]string, context.temp_allocator)
	for imp in plugin_dir_imports(dir) {
		dep := plugin_import_name(imp.path)
		if dep != owner && !slice.contains(out[:], dep) do append(&out, dep)
	}
	return out
}

// Every reason `p` needs another plugin: its imports (line > 0), then the
// guids in its assets and non-test code that another plugin owns (temp).
plugin_all_uses :: proc(p: Plugin_Folder, dirs: map[string]string, owners: map[string]Plugin_Owner) -> [dynamic]Plugin_Dep_Use {
	uses, reached := plugin_walk(p.name, dirs)

	// Content: the package's assets and the code the walk read, tests left
	// out (their inline scenes point at textures they never load).
	files := make([dynamic]string, context.temp_allocator)
	plugin_files(strings.join({p.dir, "assets"}, "/", context.temp_allocator), {}, &files)
	tests_dir := strings.join({p.dir, "tests"}, "/", context.temp_allocator)
	for dir in reached {
		if !strings.has_prefix(dir, p.dir) || strings.has_prefix(dir, tests_dir) do continue
		append(&files, ..plugin_dir_odin_files(dir)[:])
	}
	slice.sort(files[:])
	reached_by := make(map[string]map[string]bool, context.temp_allocator)
	for f in files {
		text, ok := plugin_read_text(f)
		if !ok do continue
		ids := make([dynamic]string, context.temp_allocator)
		plugin_scan_uuids(text, &ids)
		for id in ids {
			o, owned := owners[id]
			if !owned do continue
			// The package's own samples live in its folder: always present.
			if strings.has_prefix(dirs[o.pkg], strings.concatenate({p.dir, "/"}, context.temp_allocator)) do continue
			if o.pkg != p.name {
				append(&uses, Plugin_Dep_Use{plugin = p.name, needs = o.pkg, file = f, why = fmt.tprintf("uses %s", o.what)})
			}
			if !o.type do continue
			// A type from an integration subpackage (one its own plugin does
			// not import) also needs what that folder imports.
			if o.pkg not_in reached_by {
				_, r := plugin_walk(o.pkg, dirs)
				reached_by[o.pkg] = r
			}
			if reached_by[o.pkg][o.dir] do continue
			for dep in plugin_folder_needs(o.dir, o.pkg) {
				if dep == p.name do continue
				append(&uses, Plugin_Dep_Use{plugin = p.name, needs = dep, file = f, why = fmt.tprintf("uses %s from %s", o.what, o.dir)})
			}
		}
	}
	return uses
}

// One dependency of one plugin and what needs it, by scope:
// - compile: an import from the plugin's root, editor/ or a subpackage those
//   import. The build stops without it.
// - tests:   an import only from tests/. The test build stops without it.
// - content: a guid the other plugin owns, in assets/ or in code. What uses
//   it does not load without it, the build is fine.
Plugin_Dep_Row :: struct {
	plugin:  string,
	needs:   string,
	compile: bool,
	tests:   bool,
	content: bool,
}

// Every dependency of every plugin and sample on disk, sorted by plugin then
// dependency (temp).
plugin_deps_on_disk :: proc(root := PLUGINS_DIR) -> [dynamic]Plugin_Dep_Row {
	pkgs := plugin_folders(root)
	dirs := make(map[string]string, context.temp_allocator)
	for p in pkgs do dirs[p.name] = p.dir
	owners := plugin_owners(pkgs[:])
	rows := make([dynamic]Plugin_Dep_Row, context.temp_allocator)
	for p in pkgs {
		at := make(map[string]int, context.temp_allocator)
		tests_dir := strings.concatenate({p.dir, "/tests/"}, context.temp_allocator)
		for u in plugin_all_uses(p, dirs, owners) {
			if u.needs == p.name do continue
			i, has := at[u.needs]
			if !has {
				i = len(rows)
				at[u.needs] = i
				append(&rows, Plugin_Dep_Row{plugin = p.name, needs = u.needs})
			}
			switch {
			case u.line == 0:                          rows[i].content = true
			case strings.has_prefix(u.file, tests_dir): rows[i].tests = true
			case:                                      rows[i].compile = true
			}
		}
	}
	slice.sort_by(rows[:], proc(a, b: Plugin_Dep_Row) -> bool {
		if a.plugin != b.plugin do return a.plugin < b.plugin
		return a.needs < b.needs
	})
	return rows
}
