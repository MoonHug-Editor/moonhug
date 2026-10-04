package main

// `mh deps [name ...]` (docs/core/Plugins.md, "Plugin manifest"): gathers each
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

	r, changed, ok := gen_facts.plugin_manifest_sync(p, found[:])
	if !ok do return false
	if r.made {
		fmt.printfln("%s: made %s", p.name, r.path)
		return true
	}
	if !changed {
		fmt.printfln("%s: up to date", p.name)
		return true
	}
	fmt.printfln("%s:", p.name)
	for d in r.added do fmt.printfln("  + %s  (%s)", d, reason[d])
	for d in r.removed do fmt.printfln("  - %s  (nothing found uses it)", d)
	return true
}
