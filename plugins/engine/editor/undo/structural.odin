package scene_undo

// Records the engine's structural edits on the undo stack: reparent, create,
// delete, and component add, remove and reorder. Each helper builds an
// undo_ops command from the live world and pushes it.

import "core:encoding/json"
import shell "moonhug:editor/undo"
import engine "moonhug:packages/engine"
import "moonhug:packages/engine/editor/undo_ops"

scene_ref :: proc(s: ^engine.Scene) -> shell.Scene_Ref {
	if s == nil do return {}
	return shell.Scene_Ref{id = s.session_id}
}

resolve_scene :: proc(r: shell.Scene_Ref) -> ^engine.Scene {
	return engine.sm_scene_find_by_session_id(r.id)
}


capture_transform_subtree :: proc(tH: engine.Transform_Handle) -> []byte {
	return engine.scene_copy_subtree(tH)
}

capture_component_json :: proc(ptr: rawptr, tid: typeid) -> []byte {
	return shell.capture_json(ptr, tid)
}

transform_scene_and_local_id :: proc(tH: engine.Transform_Handle) -> (^engine.Scene, engine.Local_ID, bool) {
	w := engine.ctx_world()
	if w == nil do return nil, 0, false
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return nil, 0, false
	return t.scene, t.local_id, true
}

parent_local_id :: proc(tH: engine.Transform_Handle) -> engine.Local_ID {
	w := engine.ctx_world()
	if w == nil do return 0
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return 0
	if !engine.pool_valid(&w.transforms, t.parent.handle) do return 0
	pt := engine.pool_get(&w.transforms, t.parent.handle)
	if pt == nil do return 0
	return pt.local_id
}

record_reparent :: proc(node: engine.Transform_Handle, old_parent, new_parent: engine.Transform_Handle, old_index, new_index: int) {
	s := shell.get()
	if s == nil || !s.recording || s.applying do return

	scene, node_lid, ok := transform_scene_and_local_id(node)
	if !ok do return

	w := engine.ctx_world()
	old_parent_lid: engine.Local_ID
	if engine.pool_valid(&w.transforms, engine.Handle(old_parent)) {
		if opt := engine.pool_get(&w.transforms, engine.Handle(old_parent)); opt != nil {
			old_parent_lid = opt.local_id
		}
	}
	new_parent_lid: engine.Local_ID
	if engine.pool_valid(&w.transforms, engine.Handle(new_parent)) {
		if npt := engine.pool_get(&w.transforms, engine.Handle(new_parent)); npt != nil {
			new_parent_lid = npt.local_id
		}
	}

	cmd := undo_ops.Reparent_Command{
		scene = scene_ref(scene),
		node_local_id = node_lid,
		old_parent_local_id = old_parent_lid,
		new_parent_local_id = new_parent_lid,
		old_index = old_index,
		new_index = new_index,
	}
	shell.push(s, shell.Command(cmd))
}

record_create :: proc(root: engine.Transform_Handle, parent: engine.Transform_Handle) {
	s := shell.get()
	if s == nil || !s.recording || s.applying do return

	scene, root_lid, ok := transform_scene_and_local_id(root)
	if !ok do return
	parent_lid: engine.Local_ID
	w := engine.ctx_world()
	if engine.pool_valid(&w.transforms, engine.Handle(parent)) {
		if pt := engine.pool_get(&w.transforms, engine.Handle(parent)); pt != nil {
			parent_lid = pt.local_id
		}
	}

	// Prefab content must be captured too, or undo of a nested delete has
	// nothing to restore.
	payload := engine.scene_copy_subtree(root, include_nested_owned = true)
	if payload == nil do return

	sibling_idx := engine.transform_get_sibling_index(root)
	cmd := undo_ops.Create_Subtree_Command{
		scene = scene_ref(scene),
		parent_local_id = parent_lid,
		root_local_id = root_lid,
		sibling_index = sibling_idx,
		payload = payload,
	}
	shell.push(s, shell.Command(cmd))
}

record_delete_pre :: proc(root: engine.Transform_Handle) -> (undo_ops.Delete_Subtree_Command, bool) {
	s := shell.get()
	if s == nil || !s.recording || s.applying do return {}, false

	scene, root_lid, ok := transform_scene_and_local_id(root)
	if !ok do return {}, false
	parent_lid := parent_local_id(root)

	// Prefab content must be captured too, or undo of a nested delete has
	// nothing to restore.
	payload := engine.scene_copy_subtree(root, include_nested_owned = true)
	if payload == nil do return {}, false

	sibling_idx := engine.transform_get_sibling_index(root)
	owned := false
	if w := engine.ctx_world(); w != nil {
		if rt := engine.pool_get(&w.transforms, engine.Handle(root)); rt != nil {
			owned = rt.nested_owned
		}
	}
	return undo_ops.Delete_Subtree_Command{
		scene = scene_ref(scene),
		parent_local_id = parent_lid,
		root_local_id = root_lid,
		sibling_index = sibling_idx,
		payload = payload,
		nested_owned = owned,
	}, true
}

record_commit :: proc(cmd: ^$T) {
	s := shell.get()
	if s == nil do return
	if cmd.payload == nil do return
	pushed := cmd^
	cmd.payload = nil
	shell.push(s, shell.Command(pushed))
}

record_cleanup :: proc(cmd: ^$T) {
	if cmd.payload != nil {
		delete(cmd.payload)
		cmd.payload = nil
	}
}

record_add_component :: proc(owner_tH: engine.Transform_Handle, comp_handle: engine.Handle, list_index: int) {
	s := shell.get()
	if s == nil || !s.recording || s.applying do return
	w := engine.ctx_world()
	if w == nil do return
	base := engine.world_pool_get(w, comp_handle)
	if base == nil do return
	cbase := cast(^engine.CompData)base
	tid := engine.get_typeid_by_type_key(comp_handle.type_key)
	scene, owner_lid, ok := transform_scene_and_local_id(owner_tH)
	if !ok do return

	payload := shell.capture_json(base, tid)
	cmd := undo_ops.Add_Component_Command{
		scene = scene_ref(scene),
		owner_local_id = owner_lid,
		type_key = comp_handle.type_key,
		comp_local_id = cbase.local_id,
		payload = payload,
		list_index = list_index,
	}
	shell.push(s, shell.Command(cmd))
}

record_remove_component_pre :: proc(owner_tH: engine.Transform_Handle, comp_handle: engine.Handle, list_index: int) -> (undo_ops.Remove_Component_Command, bool) {
	s := shell.get()
	if s == nil || !s.recording || s.applying do return {}, false
	w := engine.ctx_world()
	if w == nil do return {}, false
	base := engine.world_pool_get(w, comp_handle)
	if base == nil do return {}, false
	cbase := cast(^engine.CompData)base
	tid := engine.get_typeid_by_type_key(comp_handle.type_key)
	scene, owner_lid, ok := transform_scene_and_local_id(owner_tH)
	if !ok do return {}, false

	payload := shell.capture_json(base, tid)
	return undo_ops.Remove_Component_Command{
		scene = scene_ref(scene),
		owner_local_id = owner_lid,
		type_key = comp_handle.type_key,
		comp_local_id = cbase.local_id,
		payload = payload,
		list_index = list_index,
	}, true
}

// Removes a preserved unknown-component record (missing-component inspector
// row) and records the step. Self-contained — no pre/commit split: the removal
// itself lives in engine, nothing happens between capture and push.
record_remove_unknown_component :: proc(owner_tH: engine.Transform_Handle, comp_local_id: engine.Local_ID) {
	scene, owner_lid, ok := transform_scene_and_local_id(owner_tH)
	if !ok do return

	// Capture the record BEFORE removal destroys it.
	payload: []byte
	for &uc in scene.unknown_components {
		if uc.owner_lid != owner_lid || uc.local_id != comp_local_id do continue
		data, merr := json.marshal(uc.value, {spec = .JSON})
		if merr == nil do payload = data
		break
	}

	list_index, removed := engine.transform_remove_unknown_comp(owner_tH, comp_local_id)
	if !removed {
		if payload != nil do delete(payload)
		return
	}

	s := shell.get()
	if s == nil || !s.recording || s.applying || payload == nil {
		if payload != nil do delete(payload)
		return
	}
	cmd := undo_ops.Remove_Unknown_Component_Command{
		scene          = scene_ref(scene),
		owner_local_id = owner_lid,
		comp_local_id  = comp_local_id,
		payload        = payload,
		list_index     = list_index,
	}
	shell.push(s, shell.Command(cmd))
}

record_reorder_components :: proc(owner_tH: engine.Transform_Handle, from, to: int) {
	s := shell.get()
	if s == nil || !s.recording || s.applying do return
	scene, owner_lid, ok := transform_scene_and_local_id(owner_tH)
	if !ok do return
	cmd := undo_ops.Reorder_Components_Command{
		scene = scene_ref(scene),
		owner_local_id = owner_lid,
		old_index = from,
		new_index = to,
	}
	shell.push(s, shell.Command(cmd))
}

record_delete :: proc(tH: engine.Transform_Handle) {
	pre, ok := record_delete_pre(tH)
	if !ok {
		engine.transform_destroy(tH)
		return
	}
	engine.transform_destroy(tH)
	record_commit(&pre)
}

record_remove_component :: proc(owner_tH: engine.Transform_Handle, comp_handle: engine.Handle) {
	list_idx := -1
	w := engine.ctx_world()
	if w != nil {
		if t := engine.pool_get(&w.transforms, engine.Handle(owner_tH)); t != nil {
			for i in 0 ..< len(t.components) {
				if t.components[i].handle == comp_handle {
					list_idx = i
					break
				}
			}
		}
	}
	pre, ok := record_remove_component_pre(owner_tH, comp_handle, list_idx)
	if !ok {
		engine.transform_remove_comp(owner_tH, comp_handle)
		return
	}
	engine.transform_remove_comp(owner_tH, comp_handle)
	record_commit(&pre)
}

record_create_child :: proc(name: string, parent: engine.Transform_Handle) -> engine.Transform_Handle {
	tH := engine.transform_new(name, parent)
	if tH != {} {
		record_create(tH, parent)
	}
	return tH
}

record_reparent_to :: proc(node: engine.Transform_Handle, new_parent: engine.Transform_Handle, new_index: int = -1) {
	w := engine.ctx_world()
	if w == nil do return
	t := engine.pool_get(&w.transforms, engine.Handle(node))
	if t == nil do return
	old_parent := engine.Transform_Handle(t.parent.handle)
	old_index := engine.transform_get_sibling_index(node)

	// A sibling reorder keeps its locals untouched. A real parent change
	// keeps the WORLD transform, so the rewritten locals land in the same
	// undo step as the reparent.
	if new_parent == old_parent {
		engine.transform_set_parent(node, new_parent, new_index)
		final_index := engine.transform_get_sibling_index(node)
		record_reparent(node, old_parent, new_parent, old_index, final_index)
		return
	}

	g := shell.group_begin("Reparent")
	defer shell.group_end(&g)
	locals := shell.edit_session_begin({
		shell.edit_target_transform(node, &t.position, typeid_of([3]f32)),
		shell.edit_target_transform(node, &t.rotation, typeid_of([4]f32)),
		shell.edit_target_transform(node, &t.scale, typeid_of([3]f32)),
	}, "Reparent")

	engine.transform_set_parent(node, new_parent, new_index, keep_world = true)
	final_index := engine.transform_get_sibling_index(node)
	record_reparent(node, old_parent, new_parent, old_index, final_index)

	shell.edit_session_end(&locals)
	shell.group_commit(&g)
}
