package mesh_editor

// Editor half of the engine's mesh components: the MeshFilter mesh/part
// picker and the model files' sub-asset provider (parts, then clips, then
// convex decompositions, in the project window). This is the ONE provider for model files: the registry
// keeps the last registration per extension, so a second provider for .glb
// silently replaces whichever ran first. Compiled into the editor binary only.

import "base:runtime"
import "core:encoding/uuid"
import "core:fmt"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "moonhug:packages/engine"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/inspector"
import "moonhug:editor/subassets"
import "moonhug:editor/widgets"
import assets "moonhug:libs/assets"

_MODEL_EXTS := [?]string{".glb", ".gltf"}

_is_model_path :: proc(path: string) -> bool {
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	for e in _MODEL_EXTS do if ext == e do return true
	return false
}

@(provider_install)
mesh_editor_install :: proc() {
	inspector.add_component_wrapper(typeid_of(engine.MeshFilter), _mesh_filter_inspector)
	for ext in _MODEL_EXTS {
		subassets.register(ext, subassets.Provider{list = _model_sub_assets})
	}
}

// Parts first, then the clips baked from the model's animations
// (engine.Mesh_Clip), then its convex decompositions (engine.Mesh_Hull_Set).
// An orphan clip, gone from the model but still referenced, stays listed so
// its section can remap it.
_model_sub_assets :: proc(path: string, allocator: runtime.Allocator) -> []subassets.Sub_Asset {
	guid, ok := engine.asset_db_get_guid(path)
	if !ok do return nil
	parts := engine.mesh_parts(engine.Asset_GUID(guid))
	clips := engine.mesh_clips(engine.Asset_GUID(guid))
	sets := engine.mesh_hull_sets(engine.Asset_GUID(guid))
	if len(parts) + len(clips) + len(sets) == 0 do return nil
	out := make([dynamic]subassets.Sub_Asset, 0, len(parts) + len(clips) + len(sets), allocator)
	for p in parts do append(&out, subassets.Sub_Asset{id = p.id, name = p.name})
	for c in clips {
		name := c.orphan ? fmt.aprintf("%s (missing)", c.name, allocator = allocator) : c.name
		append(&out, subassets.Sub_Asset{id = c.id, name = name})
	}
	for st in sets do append(&out, subassets.Sub_Asset{id = st.id, name = strings.clone(hull_set_name(engine.Asset_GUID(guid), st), allocator)})
	return out[:]
}

// A convex decomposition's name, from what it is: "Hulls 8, 0.050", the
// remesh resolution when it is not the default, and the part's name first
// when it decomposes a part. Temp-allocated.
hull_set_name :: proc(guid: engine.Asset_GUID, s: engine.Mesh_Hull_Set) -> string {
	name := fmt.tprintf("Hulls %d, %.3f", s.max_hulls, s.concavity)
	if s.remesh_resolution != engine.MESH_HULL_REMESH_DEFAULT do name = fmt.tprintf("%s, remesh %d", name, s.remesh_resolution)
	if s.part == 0 do return name
	for p in engine.mesh_parts(guid) do if p.id == s.part do return fmt.tprintf("%s %s", p.name, name)
	return fmt.tprintf("(missing part) %s", name)
}

_mesh_display :: proc(ref: engine.PPtr) -> string {
	if engine.asset_guid_is_empty(ref.guid) do return "None"
	path, pok := engine.asset_db_get_path(uuid.Identifier(ref.guid))
	if !pok do return fmt.tprintf("%v", ref.guid)
	base := filepath.stem(filepath.base(path))
	if ref.local_id == 0 do return base
	for p in engine.mesh_parts(ref.guid) {
		if p.id == ref.local_id do return fmt.tprintf("%s/%s", base, p.name)
	}
	return fmt.tprintf("%s/(missing)", base)
}

// Default fields, then the Mesh object row.
_mesh_filter_inspector :: proc(ctx: ^inspector.Component_Ctx) {
	inspector.draw(ctx)
	mf := cast(^engine.MeshFilter)ctx.ptr
	mesh_ref_row(&mf.mesh)
}

// The Mesh object row for any component with a `mesh: PPtr` field, the
// sprites picker's shape: a flat list of every model and its parts. Dropping
// a model file assigns the whole model, dropping a part row (project window)
// the exact part. A change marks the inspector changed and records the
// instance override, as the default rows do. `tooltip` explains the row.
mesh_ref_row :: proc(ref: ^engine.PPtr, label: cstring = "Mesh", tooltip: cstring = "") {
	has_value := !engine.asset_guid_is_empty(ref.guid)
	display := _mesh_display(ref^)

	value_clicked, value_double, cleared: bool
	dropped: string
	dropped_ref: engine.PPtr
	dropped_ref_ok: bool
	if inspector.picker_field_row(label, display, has_value, &value_clicked, &cleared, &value_double, &dropped, &dropped_ref, &dropped_ref_ok) {
		im.OpenPopup("mesh_picker")
	}
	if tooltip != "" do widgets.tooltip(tooltip)
	if value_clicked && has_value {
		engine.inspector_request_ping_asset(ref.guid)
	}
	if cleared {
		_set_mesh(ref, {})
	}
	if dropped != "" && _is_model_path(dropped) {
		if guid, gok := engine.asset_db_get_guid(dropped); gok {
			_set_mesh(ref, engine.PPtr{guid = engine.Asset_GUID(guid)})
		}
	}
	if dropped_ref_ok {
		// A model row carries parts AND clips. Only a part (or the whole
		// model, id 0) is a mesh.
		_, is_part := engine.mesh_part_index(dropped_ref.guid, dropped_ref.local_id)
		if path, pok := engine.asset_db_get_path(uuid.Identifier(dropped_ref.guid)); pok && _is_model_path(path) && (dropped_ref.local_id == 0 || is_part) {
			_set_mesh(ref, dropped_ref)
		}
	}

	if im.BeginPopup("mesh_picker") {
		search := inspector.picker_search_bar()
		if im.Selectable("None") {
			_set_mesh(ref, {})
		}
		im.Separator()
		if picked, ok := _mesh_picker_rows(search, ref^); ok {
			_set_mesh(ref, picked)
		}
		im.EndPopup()
	}
}

// Every model (whole) and every part, "model" or "model/part", name-filtered.
// Row IDs scope by list order, never by the reference.
_mesh_picker_rows :: proc(search: []string, current: engine.PPtr) -> (picked: engine.PPtr, ok: bool) {
	row :: proc(label: string, ref: engine.PPtr, current: engine.PPtr, search: []string, shown: ^int, picked: ^engine.PPtr, ok: ^bool) {
		if !widgets.search_match(label, search) do return
		shown^ += 1
		c_label := strings.clone_to_cstring(fmt.tprintf("%s##row_%d", label, shown^), context.temp_allocator)
		if im.Selectable(c_label, ref == current) {
			picked^ = ref
			ok^ = true
		}
	}

	paths := make([dynamic]string, context.temp_allocator)
	for path in assets.asset_db.path_to_guid {
		if _is_model_path(path) do append(&paths, path)
	}
	slice.sort(paths[:])

	shown := 0
	for path in paths {
		guid, _ := engine.asset_db_get_guid(path)
		base := filepath.stem(filepath.base(path))
		row(base, engine.PPtr{guid = engine.Asset_GUID(guid)}, current, search, &shown, &picked, &ok)
		for p in engine.mesh_parts(engine.Asset_GUID(guid)) {
			if p.id == 0 do continue
			label := fmt.tprintf("%s/%s", base, p.name)
			row(label, engine.PPtr{guid = engine.Asset_GUID(guid), local_id = p.id}, current, search, &shown, &picked, &ok)
		}

	}
	if shown == 0 do im.TextDisabled("(no matches)")
	return picked, ok
}

_set_mesh :: proc(field: ^engine.PPtr, ref: engine.PPtr) {
	if field^ == ref do return
	field^ = ref
	inspector.mark_inspector_changed()
	inspector.record_nested_override(field, typeid_of(engine.PPtr), "mesh", true)
}
