package asset_pipeline

// Importer registry: the asset pipeline dispatches through these descs, so a
// package can ship an importer without the shell knowing it. The engine's
// importers (plugins/engine/editor/importers) register on the ImportersInit phase
// like any package importer (packages subscribe with order >= 1).
//
// Rules:
// - `name` is the stable importer id. It is stored in .meta files and seeds
//   artifact keys — renaming it re-imports every asset the importer owns.
// - Bump `version` when the importer's OUTPUT changes. Its artifacts
//   re-import on the next run, nothing else does, and no one hand-deletes
//   library/.
// - `extensions` are ".png"-style, lowercase. Desc strings and slices need
//   process lifetime (package-level variables or literals).
// - `settings_tid` is the importer's settings struct, declared in the
//   importer's own package with @(typ_guid) and a reset_X next to it. That
//   provides the defaults: the pipeline creates instances through
//   create_instance_by_type_key and overlays the meta's settings object, so
//   fields absent from old metas keep their defaults. `run` receives a
//   pointer to that instance (nil when the meta's importer mismatches).
// - `artifacts` is optional: every artifact file the importer wrote for one
//   source, the main one first. The pipeline moves them together when the
//   importer refines its settings. nil = the main artifact only.
// - `sub_assets` is optional: registers the sub-asset guids the source
//   declares (assets.asset_db_set_subs). The pipeline calls it when the scan
//   first sees the source and after every import.

import "base:runtime"

Importer_Desc :: struct {
	name:         string,
	version:      int,
	extensions:   []string,
	settings_tid: typeid,
	run:          proc(source_path, artifact_path: string, settings: rawptr) -> bool,
	artifacts:    proc(artifact_path: string, allocator: runtime.Allocator) -> []string,
	sub_assets:   proc(source_path: string),
}

Phase_Extra :: enum {
	ImportersInit,
}

_importers:       map[string]Importer_Desc // by name
_importer_by_ext: map[string]string        // extension -> importer name

// The importer name owning an extension ("" when none). The inspector's
// asset funnel keys wrappers by it.
importer_for_extension :: proc(ext: string) -> string {
	return _importer_by_ext[ext] or_else ""
}

@(init)
_importer_registry_maps_init :: proc "contextless" () {
	context = runtime.default_context()
	alloc := runtime.default_allocator()
	_importers       = make(map[string]Importer_Desc, alloc)
	_importer_by_ext = make(map[string]string, alloc)
}

importer_register :: proc(desc: Importer_Desc) {
	// Process-global registry: never borrow the caller's allocator (tests hand
	// out scoped tracking allocators that tear down afterwards).
	context.allocator = runtime.default_allocator()
	_importers[desc.name] = desc
	for ext in desc.extensions {
		_importer_by_ext[ext] = desc.name
	}
}

// Runs the importer's sub-asset hook for `source_path`, when its extension has
// an importer that declares one.
_register_sub_assets :: proc(source_path: string, ext: string) {
	name := _importer_by_ext[ext] or_else ""
	if desc, ok := _importers[name]; ok && desc.sub_assets != nil {
		desc.sub_assets(source_path)
	}
}
