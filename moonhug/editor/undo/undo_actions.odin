package undo

import engine "../../engine"

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
	s := get()
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

	cmd := Reparent_Command{
		scene = scene,
		node_local_id = node_lid,
		old_parent_local_id = old_parent_lid,
		new_parent_local_id = new_parent_lid,
		old_index = old_index,
		new_index = new_index,
	}
	push(s, Command(Structural_Command(cmd)))
}

record_create :: proc(root: engine.Transform_Handle, parent: engine.Transform_Handle) {
	s := get()
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

	payload := engine.scene_copy_subtree(root)
	if payload == nil do return

	sibling_idx := engine.transform_get_sibling_index(root)
	cmd := Create_Subtree_Command{
		scene = scene,
		parent_local_id = parent_lid,
		root_local_id = root_lid,
		sibling_index = sibling_idx,
		payload = payload,
	}
	push(s, Command(Structural_Command(cmd)))
}

record_delete_pre :: proc(root: engine.Transform_Handle) -> (Delete_Subtree_Command, bool) {
	s := get()
	if s == nil || !s.recording || s.applying do return {}, false

	scene, root_lid, ok := transform_scene_and_local_id(root)
	if !ok do return {}, false
	parent_lid := parent_local_id(root)

	payload := engine.scene_copy_subtree(root)
	if payload == nil do return {}, false

	sibling_idx := engine.transform_get_sibling_index(root)
	return Delete_Subtree_Command{
		scene = scene,
		parent_local_id = parent_lid,
		root_local_id = root_lid,
		sibling_index = sibling_idx,
		payload = payload,
	}, true
}

record_commit :: proc(cmd: ^$T) {
	s := get()
	if s == nil do return
	if cmd.payload == nil do return
	pushed := cmd^
	cmd.payload = nil
	push(s, Command(Structural_Command(pushed)))
}

record_cleanup :: proc(cmd: ^$T) {
	if cmd.payload != nil {
		delete(cmd.payload)
		cmd.payload = nil
	}
}

record_add_component :: proc(owner_tH: engine.Transform_Handle, comp_handle: engine.Handle, list_index: int) {
	s := get()
	if s == nil || !s.recording || s.applying do return
	w := engine.ctx_world()
	if w == nil do return
	base := engine.world_pool_get(w, comp_handle)
	if base == nil do return
	cbase := cast(^engine.CompData)base
	tid := engine.get_typeid_by_type_key(comp_handle.type_key)
	scene, owner_lid, ok := transform_scene_and_local_id(owner_tH)
	if !ok do return

	payload := capture_json(base, tid)
	cmd := Add_Component_Command{
		scene = scene,
		owner_local_id = owner_lid,
		type_key = comp_handle.type_key,
		comp_local_id = cbase.local_id,
		payload = payload,
		list_index = list_index,
	}
	push(s, Command(Structural_Command(cmd)))
}

record_remove_component_pre :: proc(owner_tH: engine.Transform_Handle, comp_handle: engine.Handle, list_index: int) -> (Remove_Component_Command, bool) {
	s := get()
	if s == nil || !s.recording || s.applying do return {}, false
	w := engine.ctx_world()
	if w == nil do return {}, false
	base := engine.world_pool_get(w, comp_handle)
	if base == nil do return {}, false
	cbase := cast(^engine.CompData)base
	tid := engine.get_typeid_by_type_key(comp_handle.type_key)
	scene, owner_lid, ok := transform_scene_and_local_id(owner_tH)
	if !ok do return {}, false

	payload := capture_json(base, tid)
	return Remove_Component_Command{
		scene = scene,
		owner_local_id = owner_lid,
		type_key = comp_handle.type_key,
		comp_local_id = cbase.local_id,
		payload = payload,
		list_index = list_index,
	}, true
}

record_reorder_components :: proc(owner_tH: engine.Transform_Handle, from, to: int) {
	s := get()
	if s == nil || !s.recording || s.applying do return
	scene, owner_lid, ok := transform_scene_and_local_id(owner_tH)
	if !ok do return
	cmd := Reorder_Components_Command{
		scene = scene,
		owner_local_id = owner_lid,
		old_index = from,
		new_index = to,
	}
	push(s, Command(Structural_Command(cmd)))
}
