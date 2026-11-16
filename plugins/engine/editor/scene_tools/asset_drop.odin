package scene_tools

// What an asset becomes as an object of the scene: a file or sub-asset
// dragged into the Scene window or the Hierarchy (the asset rules of
// moonhug/editor/drag), or placed from code with asset_drop.
//
// What an asset becomes is up to the package that knows its type, with an
// @(asset_on_drop) proc. The engine's own are here: a scene becomes a nested
// instance, a model its node hierarchy with its meshes, a model part one mesh.

import "core:encoding/uuid"
import "core:fmt"
import "core:path/filepath"
import "core:strings"
import cgltf "vendor:cgltf"
import "moonhug:editor/drag"
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
//   ("scene", "png") or a sub-asset's kind ("sprite", "mesh"), as
//   drag.asset_kind names it, several separated by spaces. One proc per
//   kind, the build stops on a second.
// - The proc is named asset_on_drop_<name>.
// - The scene tools' generated asset_on_drop_generated.odin
//   (plugins/engine/gen/asset_drop_gen.odin) finds the proc for a kind.
@(extension_point={attribute="asset_on_drop", target="proc", fields="kind"})
Asset_Drop_Proc :: proc(ref: engine.PPtr, parent: engine.Transform_Handle) -> engine.Transform_Handle

// Whether some package makes an object of `ref`.
asset_drop_accepts :: proc(ref: engine.PPtr) -> bool {
	return __asset_on_drop(drag.asset_kind(ref)) != nil
}

// Makes the object `ref` becomes under `parent`, at child `index` (-1 for
// the end) and world position `at` when given, recorded on the undo stack.
// {} when nothing was made. The caller selects what it made.
asset_drop :: proc(ref: engine.PPtr, parent: engine.Transform_Handle, at: Maybe([3]f32) = nil, index := -1) -> engine.Transform_Handle {
	fn := __asset_on_drop(drag.asset_kind(ref))
	if fn == nil do return {}
	tH := fn(ref, parent)
	if tH == {} do return {}
	if p, has := at.?; has do engine.transform_set_world_position(tH, p)
	if index >= 0 do _move_to_index(tH, parent, index)
	undo.record_create(tH, parent)
	return tH
}

// Assets dropped into the Scene window: an object each, under the active
// scene's root, where the pointer meets the nearest object
// (scene_window_surface_point), or on the grid over empty space. One undo
// step, the objects selected.
@(drop={what = "asset", on = "scene"})
drop_assets_in_scene :: proc(d: ^drag.Drop) -> bool {
	refs := drag.assets_of(d.items)
	for ref in refs do if !asset_drop_accepts(ref) do return false
	scene := engine.sm_scene_get_active()
	if scene == nil do return false
	if !d.perform {
		d.hint = place_hint(refs)
		return true
	}
	p := d.place.(drag.Scene_Place)
	at := p.fallback
	if hit, ok := scene_window_surface_point(p.view, p.px, p.py); ok do at = hit
	place_assets(refs, engine.Transform_Handle(scene.root.handle), at)
	return true
}

// Makes an object of each of `refs` under `parent` (at child `index`, -1
// for the end, and at world position `at` when given) as one undo step, and
// selects them.
place_assets :: proc(refs: []engine.PPtr, parent: engine.Transform_Handle, at: Maybe([3]f32) = nil, index := -1) {
	g := undo.group_begin(len(refs) == 1 ? fmt.tprintf("Place %s", drag.asset_name(refs[0])) : "Place Assets")
	defer undo.group_end(&g)
	undo.record_selection_snapshot()
	made := make([dynamic]engine.Transform_Handle, context.temp_allocator)
	for ref, i in refs {
		if tH := asset_drop(ref, parent, at, index < 0 ? -1 : index + i); tH != {} do append(&made, tH)
	}
	if len(made) == 0 do return
	undo.group_commit(&g)
	session.select_clear()
	for tH in made do session.select_add(tH)
}

// What placing `refs` says while a drag hovers: "Place Crate", "Place 3 assets".
place_hint :: proc(refs: []engine.PPtr) -> string {
	if len(refs) == 1 do return fmt.tprintf("Place %s", drag.asset_name(refs[0]))
	return fmt.tprintf("Place %d assets", len(refs))
}

@(private = "file")
_move_to_index :: proc(tH, parent: engine.Transform_Handle, index: int) {
	w := engine.ctx_world()
	pt := engine.pool_get(&w.transforms, engine.Handle(parent))
	if pt == nil do return
	at := -1
	for c, i in pt.children do if c.handle == engine.Handle(tH) do at = i
	if at < 0 || at == index do return
	entry := pt.children[at]
	ordered_remove(&pt.children, at)
	inject_at(&pt.children, min(index, len(pt.children)), entry)
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
