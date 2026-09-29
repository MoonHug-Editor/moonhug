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

// Who owns a guid.
main :: proc() {
	// Kept for the whole run: each package's gather frees the temp allocator.
	pkgs := _packages()
	dirs := make(map[string]string)
	for p in pkgs do dirs[p.name] = p.dir
	owners := gen_facts.plugin_owners(pkgs[:])

	targets := make([dynamic]gen_facts.Plugin_Folder)
	for arg in os.args[1:] {
		dir, has := dirs[arg]
		if !has {
			fmt.eprintfln("mh deps: no plugin or sample named %q in %s/", arg, PLUGINS_DIR)
			os.exit(1)
		}
		append(&targets, gen_facts.Plugin_Folder{name = arg, dir = dir})
	}
	if len(targets) == 0 do append(&targets, ..pkgs[:])

	failed := false
	for p in targets {
		if !_gather(p, dirs, owners) do failed = true
		free_all(context.temp_allocator)
	}
	os.exit(1 if failed else 0)
}

// Every plugin and sample folder under plugins/, sorted by name. Kept for the
// whole run, so the names and dirs are cloned off the temp allocator.
_packages :: proc() -> [dynamic]gen_facts.Plugin_Folder {
	out := make([dynamic]gen_facts.Plugin_Folder)
	for p in gen_facts.plugin_folders(PLUGINS_DIR) do append(&out, gen_facts.Plugin_Folder{name = strings.clone(p.name), dir = strings.clone(p.dir)})
	return out
}







_gather :: proc(p: gen_facts.Plugin_Folder, dirs: map[string]string, owners: map[string]gen_facts.Plugin_Owner) -> bool {
	uses := gen_facts.plugin_all_uses(p, dirs, owners)

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
