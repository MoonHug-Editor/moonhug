package main

// `mh deps [name ...]` (docs/Plugins.md, "Plugin manifest"): gathers each
// package's dependencies into its mh_plugin.json. Packages are the plugins in
// plugins/ and the samples in plugins/<name>/samples/, installed or not. With
// names, only those.
//
// A dependency is found two ways:
//
// - Code: an import of another plugin from the package's root, editor/ or
//   tests/, or from a subpackage those import (gen_facts.plugin_walk).
// - Content: a guid in the package's assets or code that another package
//   owns. A type guid (@(typ_guid)) is owned by the package declaring the
//   type, an asset guid by the package whose .meta holds it. A type declared
//   in an integration subpackage also needs the plugins that folder imports: a
//   scene with an audio track needs audio and the sequencer.
//
// The gathered set is merged into the manifest: an entry nothing was found
// for is kept (it was written by hand) and reported, so removing one is a
// manual edit. A package without a manifest gets one, with a new guid.

import "core:crypto"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "moonhug:prebuild/gen_facts"

PLUGINS_DIR :: "plugins"

Package :: struct {
	name: string,
	dir:  string, // plugins/<name> or plugins/<plugin>/samples/<name>
}

// Who owns a guid.
Owner :: struct {
	pkg:  string,
	what: string, // a type name or an asset path
	dir:  string, // the declaring folder, for a type
	type: bool,
}

main :: proc() {
	// Kept for the whole run: each package's gather frees the temp allocator.
	pkgs := _packages()
	dirs := make(map[string]string)
	for p in pkgs do dirs[p.name] = p.dir
	owners := _owners(pkgs[:])

	targets := make([dynamic]Package)
	for arg in os.args[1:] {
		dir, has := dirs[arg]
		if !has {
			fmt.eprintfln("mh deps: no plugin or sample named %q in %s/", arg, PLUGINS_DIR)
			os.exit(1)
		}
		append(&targets, Package{name = arg, dir = dir})
	}
	if len(targets) == 0 do append(&targets, ..pkgs[:])

	failed := false
	for p in targets {
		if !_gather(p, dirs, owners) do failed = true
		free_all(context.temp_allocator)
	}
	os.exit(1 if failed else 0)
}

// Every plugin and sample folder under plugins/, sorted by name.
_packages :: proc() -> [dynamic]Package {
	out := make([dynamic]Package)
	for name in gen_facts.plugin_subdirs(PLUGINS_DIR) {
		dir := strings.join({PLUGINS_DIR, name}, "/")
		append(&out, Package{name = strings.clone(name), dir = dir})
		samples := strings.join({dir, "samples"}, "/", context.temp_allocator)
		for sample in gen_facts.plugin_subdirs(samples) {
			append(&out, Package{name = strings.clone(sample), dir = strings.join({samples, sample}, "/")})
		}
	}
	slice.sort_by(out[:], proc(a, b: Package) -> bool { return a.name < b.name })
	return out
}



// The guids every package owns: asset guids from .meta files, type guids from
// @(typ_guid) declarations. A plugin's samples/ belong to the samples.
_owners :: proc(pkgs: []Package) -> map[string]Owner {
	owners := make(map[string]Owner)
	for p in pkgs {
		files := make([dynamic]string, context.temp_allocator)
		gen_facts.plugin_files(p.dir, {"samples", "tests", "gen"}, &files)
		for f in files {
			if strings.has_suffix(f, ".meta") {
				data, err := os.read_entire_file(f, context.temp_allocator)
				if err != nil do continue
				ids := make([dynamic]string, context.temp_allocator)
				_scan_meta_guids(string(data), &ids)
				asset := strings.clone(f[len(p.dir) + 1:len(f) - len(".meta")])
				for id in ids do if id not_in owners do owners[strings.clone(id)] = Owner{pkg = p.name, what = asset}
			} else if strings.has_suffix(f, ".odin") && !strings.has_suffix(f, "_generated.odin") {
				data, err := os.read_entire_file(f, context.temp_allocator)
				if err != nil do continue
				dir := f[:strings.last_index_byte(f, '/')]
				decls := make([dynamic]gen_facts.Plugin_Type_Decl, context.temp_allocator)
				gen_facts.plugin_scan_typ_guids(string(data), p.name, strings.clone(dir), &decls)
				for d in decls do owners[strings.clone(d.guid)] = Owner{pkg = d.pkg, what = strings.clone(d.name), dir = d.dir, type = true}
			}
		}
	}
	return owners
}

// The guids a .meta owns: the values of its "guid" keys (the asset's, and a
// sub-asset's, a model clip's). Other uuids in it are not the asset's: the
// settings' __type_guid names an engine type.
_scan_meta_guids :: proc(src: string, out: ^[dynamic]string) {
	KEY :: "\"guid\""
	rest := src
	for {
		at := strings.index(rest, KEY)
		if at < 0 do break
		rest = rest[at + len(KEY):]
		ids := make([dynamic]string, context.temp_allocator)
		gen_facts.plugin_scan_uuids(rest[:min(len(rest), 48)], &ids)
		if len(ids) > 0 do append(out, ids[0])
	}
}

// A text file's contents, or ok=false for a binary or oversized one.
_read_text :: proc(path: string) -> (string, bool) {
	MAX :: 64 * 1024 * 1024
	info, serr := os.stat(path, context.temp_allocator)
	if serr != nil || info.size > MAX do return "", false
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return "", false
	head := data[:min(len(data), 8192)]
	if slice.contains(head, 0) do return "", false
	return string(data), true
}

// The plugins, other than `owner`, a folder's own files import: what a type
// declared there needs beyond its plugin.
_folder_needs :: proc(dir, owner: string) -> [dynamic]string {
	out := make([dynamic]string, context.temp_allocator)
	for imp in gen_facts.plugin_dir_imports(dir) {
		dep := gen_facts.plugin_import_name(imp.path)
		if dep != owner && !slice.contains(out[:], dep) do append(&out, dep)
	}
	return out
}

_gather :: proc(p: Package, dirs: map[string]string, owners: map[string]Owner) -> bool {
	uses, reached := gen_facts.plugin_walk(p.name, dirs)

	// Content: the package's assets and the code the walk read, tests left
	// out (their inline scenes point at textures they never load).
	files := make([dynamic]string, context.temp_allocator)
	gen_facts.plugin_files(strings.join({p.dir, "assets"}, "/", context.temp_allocator), {}, &files)
	tests_dir := strings.join({p.dir, "tests"}, "/", context.temp_allocator)
	for dir in reached {
		if !strings.has_prefix(dir, p.dir) || strings.has_prefix(dir, tests_dir) do continue
		append(&files, ..gen_facts.plugin_dir_odin_files(dir)[:])
	}
	slice.sort(files[:])
	reached_by := make(map[string]map[string]bool, context.temp_allocator)
	for f in files {
		text, ok := _read_text(f)
		if !ok do continue
		ids := make([dynamic]string, context.temp_allocator)
		gen_facts.plugin_scan_uuids(text, &ids)
		for id in ids {
			o, owned := owners[id]
			if !owned do continue
			// The package's own samples live in its folder: always present.
			if strings.has_prefix(dirs[o.pkg], strings.concatenate({p.dir, "/"}, context.temp_allocator)) do continue
			if o.pkg != p.name {
				append(&uses, gen_facts.Plugin_Dep_Use{plugin = p.name, needs = o.pkg, file = f, why = fmt.tprintf("uses %s", o.what)})
			}
			if !o.type do continue
			// A type from an integration subpackage (one its own plugin does
			// not import) also needs what that folder imports.
			if o.pkg not_in reached_by {
				_, r := gen_facts.plugin_walk(o.pkg, dirs)
				reached_by[o.pkg] = r
			}
			if reached_by[o.pkg][o.dir] do continue
			for dep in _folder_needs(o.dir, o.pkg) {
				if dep == p.name do continue
				append(&uses, gen_facts.Plugin_Dep_Use{plugin = p.name, needs = dep, file = f, why = fmt.tprintf("uses %s from %s", o.what, o.dir)})
			}
		}
	}

	// The first reason per dependency, in file order.
	found := make([dynamic]string, context.temp_allocator)
	reason := make(map[string]string, context.temp_allocator)
	for u in uses {
		if u.needs == p.name || u.needs in reason do continue
		append(&found, u.needs)
		reason[u.needs] = u.line > 0 ? fmt.tprintf("%s:%d imports it", u.file, u.line) : fmt.tprintf("%s %s", u.file, u.why)
	}
	slice.sort(found[:])

	m, has_manifest, ok := gen_facts.plugin_manifest_read(p.dir)
	path := strings.join({p.dir, gen_facts.PLUGIN_MANIFEST}, "/", context.temp_allocator)
	if has_manifest && !ok {
		fmt.eprintfln("mh deps: %s does not parse, fix or delete it", path)
		return false
	}
	if !has_manifest {
		context.random_generator = crypto.random_generator()
		m = gen_facts.Plugin_Manifest{name = p.name, guid = uuid.to_string(uuid.generate_v4(), context.temp_allocator)}
	}
	if m.name != p.name {
		fmt.eprintfln("mh deps: %s names the plugin %q, its folder is %q", path, m.name, p.name)
		return false
	}

	merged := make([dynamic]string, context.temp_allocator)
	append(&merged, ..m.dependencies)
	added := make([dynamic]string, context.temp_allocator)
	for d in found do if !slice.contains(m.dependencies, d) {
		append(&merged, d)
		append(&added, d)
	}
	slice.sort(merged[:])
	kept := make([dynamic]string, context.temp_allocator)
	for d in m.dependencies do if !slice.contains(found[:], d) do append(&kept, d)

	if !has_manifest {
		fmt.printfln("%s: made %s", p.name, path)
	} else if len(added) == 0 && len(kept) == 0 {
		fmt.printfln("%s: up to date", p.name)
		return true
	} else {
		fmt.printfln("%s:", p.name)
	}
	for d in added do fmt.printfln("  + %s  (%s)", d, reason[d])
	for d in kept do fmt.printfln("  = %s  (nothing found uses it, kept as written)", d)
	if has_manifest && len(added) == 0 do return true

	m.dependencies = merged[:]
	if !_write(path, m) {
		fmt.eprintfln("mh deps: failed to write %s", path)
		return false
	}
	return true
}

// The manifest in a fixed key order, one dependency list per line.
_write :: proc(path: string, m: gen_facts.Plugin_Manifest) -> bool {
	quote :: proc(s: string) -> string {
		data, err := json.marshal(s, allocator = context.temp_allocator)
		return string(data) if err == nil else "\"\""
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "{{\n  \"name\": %s,\n  \"guid\": %s,\n  \"description\": %s,\n  \"dependencies\": [", quote(m.name), quote(m.guid), quote(m.description))
	for d, i in m.dependencies {
		if i > 0 do strings.write_string(&b, ", ")
		strings.write_string(&b, quote(d))
	}
	strings.write_string(&b, "]\n}\n")
	return os.write_entire_file(path, transmute([]byte)strings.to_string(b)) == nil
}
