package mesh_editor

// Editor half of the engine's mesh components: the MeshFilter mesh/part
// picker and the model files' sub-asset provider (parts in the project
// window). Compiled into the editor binary only.

import "base:runtime"
import "core:encoding/uuid"
import "core:fmt"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "moonhug:engine"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/inspector"
import "moonhug:editor/subassets"

_MODEL_EXTS := [?]string{".glb", ".gltf"}

_is_model_path :: proc(path: string) -> bool {
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	for e in _MODEL_EXTS do if ext == e do return true
	return false
}

@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
mesh_editor_install :: proc() {
	inspector.add_component_wrapper(typeid_of(engine.MeshFilter), _mesh_filter_inspector)
	for ext in _MODEL_EXTS {
		subassets.register(ext, subassets.Provider{list = _model_sub_assets})
	}
}

_model_sub_assets :: proc(path: string, allocator: runtime.Allocator) -> []subassets.Sub_Asset {
	guid, ok := engine.asset_db_get_guid(path)
	if !ok do return nil
	parts := engine.mesh_parts(engine.Asset_GUID(guid))
	if len(parts) == 0 do return nil
	out := make([]subassets.Sub_Asset, len(parts), allocator)
	for p, i in parts {
		out[i] = subassets.Sub_Asset{id = p.id, name = p.name}
	}
	return out
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

// Default fields, then the Mesh object row — the sprites picker's shape: a
// flat list of every model and its parts. Dropping a model file assigns the
// whole model, dropping a part row (project window) the exact part.
_mesh_filter_inspector :: proc(ctx: ^inspector.Component_Ctx) {
	inspector.draw(ctx)
	mf := cast(^engine.MeshFilter)ctx.ptr

	has_value := !engine.asset_guid_is_empty(mf.mesh.guid)
	display := _mesh_display(mf.mesh)

	value_clicked, value_double, cleared: bool
	dropped: string
	dropped_ref: engine.PPtr
	dropped_ref_ok: bool
	if inspector._picker_field_row("Mesh", display, has_value, &value_clicked, &cleared, &value_double, &dropped, &dropped_ref, &dropped_ref_ok) {
		im.OpenPopup("mesh_picker")
	}
	if value_clicked && has_value {
		engine.inspector_request_ping_asset(mf.mesh.guid)
	}
	if cleared {
		_set_mesh(mf, {})
	}
	if dropped != "" && _is_model_path(dropped) {
		if guid, gok := engine.asset_db_get_guid(dropped); gok {
			_set_mesh(mf, engine.PPtr{guid = engine.Asset_GUID(guid)})
		}
	}
	if dropped_ref_ok {
		if path, pok := engine.asset_db_get_path(uuid.Identifier(dropped_ref.guid)); pok && _is_model_path(path) {
			_set_mesh(mf, dropped_ref)
		}
	}

	if im.BeginPopup("mesh_picker") {
		search := inspector._picker_search_bar()
		if im.Selectable("None") {
			_set_mesh(mf, {})
		}
		im.Separator()
		if picked, ok := _mesh_picker_rows(search, mf.mesh); ok {
			_set_mesh(mf, picked)
		}
		im.EndPopup()
	}
}

// Every model (whole) and every part, "model" or "model/part", name-filtered.
// Row IDs scope by list order, never by the reference.
_mesh_picker_rows :: proc(search: string, current: engine.PPtr) -> (picked: engine.PPtr, ok: bool) {
	row :: proc(label: string, ref: engine.PPtr, current: engine.PPtr, search: string, shown: ^int, picked: ^engine.PPtr, ok: ^bool) {
		if search != "" && !strings.contains(strings.to_lower(label, context.temp_allocator), search) do return
		shown^ += 1
		c_label := strings.clone_to_cstring(fmt.tprintf("%s##row_%d", label, shown^), context.temp_allocator)
		if im.Selectable(c_label, ref == current) {
			picked^ = ref
			ok^ = true
		}
	}

	paths := make([dynamic]string, context.temp_allocator)
	for path in engine.asset_db.path_to_guid {
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

_set_mesh :: proc(mf: ^engine.MeshFilter, ref: engine.PPtr) {
	if mf.mesh == ref do return
	mf.mesh = ref
	inspector.mark_inspector_changed()
	inspector.record_nested_override(&mf.mesh, typeid_of(engine.PPtr), "mesh", true)
}
