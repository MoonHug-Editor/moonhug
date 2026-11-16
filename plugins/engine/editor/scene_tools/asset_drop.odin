package scene_tools

// Dropping an asset into the scene: a file or sub-asset dragged from the
// Project window becomes an object. The Scene window puts it where the
// pointer meets an object, the Hierarchy under the row it is dropped on.
//
// What an asset becomes is up to the package that knows its type, with an
// @(asset_on_drop) proc. The engine's own are here: a scene becomes a nested
// instance, a model its node hierarchy with its meshes, a model part one mesh.
//
// The drop is one undo step and selects what it made.

import "core:encoding/uuid"
import "core:path/filepath"
import "core:strings"
import cgltf "vendor:cgltf"
import "moonhug:editor/session"
import "moonhug:packages/engine"
import undo "moonhug:packages/engine/editor/undo"

// Builds what a dropped asset becomes under `parent` and returns its root,
// or {} when the asset makes nothing. The root's position is left to the
// caller, which places it, records the undo step and selects it.
//
//   @(asset_on_drop={kind="sprite"})
//   asset_on_drop_sprite :: proc(ref: engine.PPtr, parent: engine.Transform_Handle) -> engine.Transform_Handle {
//       tH := engine.transform_new("Sprite", parent)
//       ...
//       return tH
//   }
//
// - `kind` is what the proc takes: a file extension without the dot
//   ("scene", "png") or a sub-asset's kind ("sprite", "mesh"), several
//   separated by spaces. One proc per kind, the build stops on a second.
// - The proc is named asset_on_drop_<name>.
// - The scene tools' generated asset_on_drop_generated.odin
//   (plugins/engine/gen/asset_drop_gen.odin) finds the proc for a kind.
@(extension_point={attribute="asset_on_drop", target="proc", fields="kind"})
Asset_Drop_Proc :: proc(ref: engine.PPtr, parent: engine.Transform_Handle) -> engine.Transform_Handle

// What `ref` is, as @(asset_on_drop) names it: the extension of its file
// without the dot, in lower case, or its sub-asset's kind. "" when the
// database does not know it.
asset_drop_kind :: proc(ref: engine.PPtr) -> string {
	if ref.local_id != 0 {
		for s in engine.asset_db_sub_assets(ref.guid) do if s.id == ref.local_id do return s.kind
		return ""
	}
	path, ok := engine.asset_db_get_path(uuid.Identifier(ref.guid))
	if !ok do return ""
	ext := filepath.ext(path)
	if len(ext) < 2 do return ""
	return strings.to_lower(ext[1:], context.temp_allocator)
}

// Whether some package makes an object of `ref`.
asset_drop_accepts :: proc(ref: engine.PPtr) -> bool {
	return __asset_on_drop(asset_drop_kind(ref)) != nil
}

// Makes the object `ref` becomes under `parent`, at world position `at` when
// given, as one undo step, and selects it. {} when nothing was made.
asset_drop :: proc(ref: engine.PPtr, parent: engine.Transform_Handle, at: Maybe([3]f32) = nil) -> engine.Transform_Handle {
	fn := __asset_on_drop(asset_drop_kind(ref))
	if fn == nil do return {}
	tH := fn(ref, parent)
	if tH == {} do return {}
	if p, has := at.?; has do engine.transform_set_world_position(tH, p)
	undo.record_create(tH, parent)
	session.select_only(tH)
	return tH
}

// The Scene window's drop at pixel (px, py) of `view`: under the active
// scene's root, where the pointer meets the nearest object
// (scene_window_surface_point), or at `fallback` over empty space.
asset_drop_in_view :: proc(view: engine.Render_View, px, py: f32, ref: engine.PPtr, fallback: [3]f32) -> engine.Transform_Handle {
	scene := engine.sm_scene_get_active()
	if scene == nil do return {}
	at := fallback
	if p, ok := scene_window_surface_point(view, px, py); ok do at = p
	return asset_drop(ref, engine.Transform_Handle(scene.root.handle), at)
}

// A scene (a prefab) becomes a nested instance of it.
@(asset_on_drop={kind="scene"})
asset_on_drop_scene :: proc(ref: engine.PPtr, parent: engine.Transform_Handle) -> engine.Transform_Handle {
	return engine.scene_instantiate_guid_nested(ref.guid, parent)
}

// A model becomes its node hierarchy, each mesh node with its part. The
// material slots stay empty, so the default material draws: Assets > Extract
// Assets gives a scene with the model's own materials.
@(asset_on_drop={kind="glb gltf"})
asset_on_drop_model :: proc(ref: engine.PPtr, parent: engine.Transform_Handle) -> engine.Transform_Handle {
	path, ok := engine.asset_db_get_path(uuid.Identifier(ref.guid))
	if !ok do return {}
	// Without its buffers: the geometry comes from the model's artifact.
	data, res := cgltf.parse_file(cgltf.options{}, strings.clone_to_cstring(path, context.temp_allocator))
	if res != .success do return {}
	defer cgltf.free(data)
	root := engine.transform_new(filepath.stem(path), parent)
	engine.scene_gltf_populate(data, root, ref.guid, nil)
	return root
}

// A model part becomes one object drawing it, with the default material.
@(asset_on_drop={kind="mesh"})
asset_on_drop_mesh :: proc(ref: engine.PPtr, parent: engine.Transform_Handle) -> engine.Transform_Handle {
	name := "Mesh"
	for s in engine.asset_db_sub_assets(ref.guid) do if s.id == ref.local_id && s.name != "" do name = s.name
	tH := engine.transform_new(name, parent)
	_, mf_raw := engine.transform_add_comp(tH, .MeshFilter)
	(cast(^engine.MeshFilter)mf_raw).mesh = ref
	engine.transform_add_comp(tH, .MeshRenderer)
	return tH
}
