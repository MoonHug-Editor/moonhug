package undo_ops

// The engine's structural undo commands: reparent, subtree create and delete,
// and component add, remove and reorder, each its own @(undo_command) with the
// bodies that redo and undo it, plus the local id lookups they share.
// This package does not import the undo stack: the generated Command union in
// moonhug/editor/undo imports it, and plugins/engine/editor/undo records.

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import engine "moonhug:packages/engine"
import core "moonhug:host/core"
import "moonhug:host/log"

@(undo_command)
Reparent_Command :: struct {
	scene:                core.Scene_Ref,
	node_local_id:        engine.Local_ID,
	old_parent_local_id:  engine.Local_ID,
	new_parent_local_id:  engine.Local_ID,
	old_index:            int,
	new_index:            int,
}

apply_Reparent_Command :: proc(v: ^Reparent_Command) {
	_do_reparent(_scene(v.scene), v.node_local_id, v.new_parent_local_id, v.new_index)
}

revert_Reparent_Command :: proc(v: ^Reparent_Command) {
	_do_reparent(_scene(v.scene), v.node_local_id, v.old_parent_local_id, v.old_index)
}

destroy_Reparent_Command :: proc(v: ^Reparent_Command) {}

label_Reparent_Command :: proc(v: ^Reparent_Command) -> string {
	return "Reparent"
}

scenes_Reparent_Command :: proc(v: ^Reparent_Command, out: ^[dynamic]core.Scene_Ref) {
	append(out, v.scene)
}

describe_Reparent_Command :: proc(v: ^Reparent_Command, b: ^strings.Builder, depth: int) {
	fmt.sbprintf(b, "%sReparent: node=%d  old_parent=%d -> new_parent=%d  (idx %d -> %d)" + "\n",
		_indent(depth),
		i64(v.node_local_id),
		i64(v.old_parent_local_id),
		i64(v.new_parent_local_id),
		v.old_index,
		v.new_index)
}

@(undo_command)
Create_Subtree_Command :: struct {
	scene:               core.Scene_Ref,
	parent_local_id:     engine.Local_ID,
	root_local_id:       engine.Local_ID,
	sibling_index:       int,
	payload:             []byte,
}

apply_Create_Subtree_Command :: proc(v: ^Create_Subtree_Command) {
	parent_h, ok := _find_transform_for_undo(_scene(v.scene), v.parent_local_id)
	if !ok do return
	_paste_subtree_preserve_ids(v.payload, engine.Transform_Handle(parent_h), v.sibling_index)
}

revert_Create_Subtree_Command :: proc(v: ^Create_Subtree_Command) {
	node_h, ok := _find_transform_for_undo(_scene(v.scene), v.root_local_id)
	if !ok do return
	engine.transform_destroy(engine.Transform_Handle(node_h))
}

destroy_Create_Subtree_Command :: proc(v: ^Create_Subtree_Command) {
	if v.payload != nil do delete(v.payload)
}

label_Create_Subtree_Command :: proc(v: ^Create_Subtree_Command) -> string {
	return "Create"
}

scenes_Create_Subtree_Command :: proc(v: ^Create_Subtree_Command, out: ^[dynamic]core.Scene_Ref) {
	append(out, v.scene)
}

describe_Create_Subtree_Command :: proc(v: ^Create_Subtree_Command, b: ^strings.Builder, depth: int) {
	fmt.sbprintf(b, "%sCreate: parent=%d  root=%d  idx=%d  payload=%d bytes" + "\n",
		_indent(depth),
		i64(v.parent_local_id),
		i64(v.root_local_id),
		v.sibling_index,
		len(v.payload))
}

@(undo_command)
Delete_Subtree_Command :: struct {
	scene:               core.Scene_Ref,
	parent_local_id:     engine.Local_ID,
	root_local_id:       engine.Local_ID,
	sibling_index:       int,
	payload:             []byte,
	// The subtree was PREFAB CONTENT (nested_owned). Restoring it has to put
	// that back, or the next save would treat the restored rows as a host
	// addition and emit them into the host file.
	nested_owned:        bool,
}

apply_Delete_Subtree_Command :: proc(v: ^Delete_Subtree_Command) {
	node_h, ok := _find_transform_for_undo(_scene(v.scene), v.root_local_id)
	if !ok do return
	engine.transform_destroy(engine.Transform_Handle(node_h))
}

revert_Delete_Subtree_Command :: proc(v: ^Delete_Subtree_Command) {
	parent_h, ok := _find_transform_for_undo(_scene(v.scene), v.parent_local_id)
	if !ok do return
	root := _paste_subtree_preserve_ids(v.payload, engine.Transform_Handle(parent_h), v.sibling_index)
	if v.nested_owned && root != {} {
		engine.transform_mark_subtree_nested_owned(root)
	}
}

destroy_Delete_Subtree_Command :: proc(v: ^Delete_Subtree_Command) {
	if v.payload != nil do delete(v.payload)
}

label_Delete_Subtree_Command :: proc(v: ^Delete_Subtree_Command) -> string {
	return "Delete"
}

scenes_Delete_Subtree_Command :: proc(v: ^Delete_Subtree_Command, out: ^[dynamic]core.Scene_Ref) {
	append(out, v.scene)
}

describe_Delete_Subtree_Command :: proc(v: ^Delete_Subtree_Command, b: ^strings.Builder, depth: int) {
	fmt.sbprintf(b, "%sDelete: parent=%d  root=%d  idx=%d  payload=%d bytes" + "\n",
		_indent(depth),
		i64(v.parent_local_id),
		i64(v.root_local_id),
		v.sibling_index,
		len(v.payload))
}

@(undo_command)
Add_Component_Command :: struct {
	scene:               core.Scene_Ref,
	owner_local_id:      engine.Local_ID,
	type_key:            engine.TypeKey,
	comp_local_id:       engine.Local_ID,
	payload:             []byte,
	list_index:          int,
}

apply_Add_Component_Command :: proc(v: ^Add_Component_Command) {
	_do_add_component(v^)
}

revert_Add_Component_Command :: proc(v: ^Add_Component_Command) {
	sc := _scene(v.scene)
	comp_h, ok := scene_find_component_by_local_id(sc, v.comp_local_id)
	if !ok do return
	owner_h, oh_ok := scene_find_transform_by_local_id(sc, v.owner_local_id)
	if !oh_ok do return
	engine.transform_remove_comp(engine.Transform_Handle(owner_h), comp_h)
}

destroy_Add_Component_Command :: proc(v: ^Add_Component_Command) {
	if v.payload != nil do delete(v.payload)
}

label_Add_Component_Command :: proc(v: ^Add_Component_Command) -> string {
	return "Add Component"
}

scenes_Add_Component_Command :: proc(v: ^Add_Component_Command, out: ^[dynamic]core.Scene_Ref) {
	append(out, v.scene)
}

describe_Add_Component_Command :: proc(v: ^Add_Component_Command, b: ^strings.Builder, depth: int) {
	fmt.sbprintf(b, "%sAdd Component: owner=%d  type=%v  comp_local_id=%d  idx=%d  payload=%d bytes" + "\n",
		_indent(depth),
		i64(v.owner_local_id),
		v.type_key,
		i64(v.comp_local_id),
		v.list_index,
		len(v.payload))
}

@(undo_command)
Remove_Component_Command :: struct {
	scene:               core.Scene_Ref,
	owner_local_id:      engine.Local_ID,
	type_key:            engine.TypeKey,
	comp_local_id:       engine.Local_ID,
	payload:             []byte,
	list_index:          int,
}

apply_Remove_Component_Command :: proc(v: ^Remove_Component_Command) {
	sc := _scene(v.scene)
	comp_h, ok := scene_find_component_by_local_id(sc, v.comp_local_id)
	if !ok do return
	owner_h, oh_ok := scene_find_transform_by_local_id(sc, v.owner_local_id)
	if !oh_ok do return
	engine.transform_remove_comp(engine.Transform_Handle(owner_h), comp_h)
}

revert_Remove_Component_Command :: proc(v: ^Remove_Component_Command) {
	add: Add_Component_Command = {
		scene = v.scene,
		owner_local_id = v.owner_local_id,
		type_key = v.type_key,
		comp_local_id = v.comp_local_id,
		payload = v.payload,
		list_index = v.list_index,
	}
	_do_add_component(add)
}

destroy_Remove_Component_Command :: proc(v: ^Remove_Component_Command) {
	if v.payload != nil do delete(v.payload)
}

label_Remove_Component_Command :: proc(v: ^Remove_Component_Command) -> string {
	return "Remove Component"
}

scenes_Remove_Component_Command :: proc(v: ^Remove_Component_Command, out: ^[dynamic]core.Scene_Ref) {
	append(out, v.scene)
}

describe_Remove_Component_Command :: proc(v: ^Remove_Component_Command, b: ^strings.Builder, depth: int) {
	fmt.sbprintf(b, "%sRemove Component: owner=%d  type=%v  comp_local_id=%d  idx=%d  payload=%d bytes" + "\n",
		_indent(depth),
		i64(v.owner_local_id),
		v.type_key,
		i64(v.comp_local_id),
		v.list_index,
		len(v.payload))
}

@(undo_command)
Reorder_Components_Command :: struct {
	scene:               core.Scene_Ref,
	owner_local_id:      engine.Local_ID,
	old_index:           int,
	new_index:           int,
}

apply_Reorder_Components_Command :: proc(v: ^Reorder_Components_Command) {
	_do_reorder_components(_scene(v.scene), v.owner_local_id, v.old_index, v.new_index)
}

revert_Reorder_Components_Command :: proc(v: ^Reorder_Components_Command) {
	_do_reorder_components(_scene(v.scene), v.owner_local_id, v.new_index, v.old_index)
}

destroy_Reorder_Components_Command :: proc(v: ^Reorder_Components_Command) {}

label_Reorder_Components_Command :: proc(v: ^Reorder_Components_Command) -> string {
	return "Reorder Components"
}

scenes_Reorder_Components_Command :: proc(v: ^Reorder_Components_Command, out: ^[dynamic]core.Scene_Ref) {
	append(out, v.scene)
}

describe_Reorder_Components_Command :: proc(v: ^Reorder_Components_Command, b: ^strings.Builder, depth: int) {
	fmt.sbprintf(b, "%sReorder Components: owner=%d  %d -> %d" + "\n",
		_indent(depth),
		i64(v.owner_local_id),
		v.old_index,
		v.new_index)
}

// Removal of a PRESERVED unknown-component record (the component's package
// isn't compiled in — no type_key, no live pool instance). `payload` is the
// marshaled record, undo re-stashes it verbatim.
@(undo_command)
Remove_Unknown_Component_Command :: struct {
	scene:               core.Scene_Ref,
	owner_local_id:      engine.Local_ID,
	comp_local_id:       engine.Local_ID,
	payload:             []byte,
	list_index:          int,
}

apply_Remove_Unknown_Component_Command :: proc(v: ^Remove_Unknown_Component_Command) {
	owner_h, ok := scene_find_transform_by_local_id(_scene(v.scene), v.owner_local_id)
	if !ok do return
	engine.transform_remove_unknown_comp(engine.Transform_Handle(owner_h), v.comp_local_id)
}

revert_Remove_Unknown_Component_Command :: proc(v: ^Remove_Unknown_Component_Command) {
	owner_h, ok := scene_find_transform_by_local_id(_scene(v.scene), v.owner_local_id)
	if !ok do return
	val, perr := json.parse(v.payload, .JSON, true, context.temp_allocator)
	if perr != nil do return
	// transform_restore_unknown_comp clones `val` — the temp parse dies with the frame.
	engine.transform_restore_unknown_comp(engine.Transform_Handle(owner_h), v.comp_local_id, val, v.list_index)
}

destroy_Remove_Unknown_Component_Command :: proc(v: ^Remove_Unknown_Component_Command) {
	if v.payload != nil do delete(v.payload)
}

label_Remove_Unknown_Component_Command :: proc(v: ^Remove_Unknown_Component_Command) -> string {
	return "Remove Missing Component"
}

scenes_Remove_Unknown_Component_Command :: proc(v: ^Remove_Unknown_Component_Command, out: ^[dynamic]core.Scene_Ref) {
	append(out, v.scene)
}

describe_Remove_Unknown_Component_Command :: proc(v: ^Remove_Unknown_Component_Command, b: ^strings.Builder, depth: int) {
	fmt.sbprintf(b, "%sRemove Missing Component: owner=%d  comp_local_id=%d  idx=%d  payload=%d bytes" + "\n",
		_indent(depth),
		i64(v.owner_local_id),
		i64(v.comp_local_id),
		v.list_index,
		len(v.payload))
}

// --- Lookups ----------------------------------------------------------------

// The loaded scene a command recorded, nil once it is gone.
@(private)
_scene :: proc(r: core.Scene_Ref) -> ^engine.Scene {
	return engine.sm_scene_find_by_session_id(r.id)
}

scene_find_transform_by_local_id :: proc(s: ^engine.Scene, id: engine.Local_ID) -> (engine.Handle, bool) {
	tH, ok := engine.scene_find_outer_transform_local_id(s, id)
	if !ok do return {}, false
	return engine.Handle(tH), true
}

scene_find_component_by_local_id :: proc(s: ^engine.Scene, id: engine.Local_ID) -> (engine.Handle, bool) {
	if s == nil || id == 0 do return {}, false
	w := engine.ctx_world()
	if w == nil do return {}, false
	it := engine.pool_iterator(&w.transforms)
	for t, _ in engine.pool_next(&it) {
		if t.scene != s do continue
		if t.nested_owned do continue
		for c in t.components {
			if c.local_id == id && c.handle.type_key != engine.INVALID_TYPE_KEY {
				raw := engine.world_pool_get(w, c.handle)
				if raw != nil {
					base := cast(^engine.CompData)raw
					if base.nested_owned do continue
				}
				return c.handle, true
			}
		}
	}
	return {}, false
}

// The history view's indent, two spaces per depth level.
@(private)
_indent :: proc(depth: int) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for _ in 0 ..< depth {
		strings.write_string(&b, "  ")
	}
	return strings.to_string(b)
}

// --- Bodies -----------------------------------------------------------------

@(private)
_do_reparent :: proc(s: ^engine.Scene, node_id: engine.Local_ID, new_parent_id: engine.Local_ID, new_index: int) {
	node_h, ok := scene_find_transform_by_local_id(s, node_id)
	if !ok do return
	parent_h: engine.Handle
	if new_parent_id != 0 {
		p, pok := scene_find_transform_by_local_id(s, new_parent_id)
		if !pok do return
		parent_h = p
	} else {
		if s == nil do return
		parent_h = s.root.handle
	}
	engine.transform_set_parent(engine.Transform_Handle(node_h), engine.Transform_Handle(parent_h), new_index)
}

// Transform lookup for undo/redo of structural edits. PREFAB CONTENT is not in
// the scene bimap — composed instance lids belong to the instance, not the host
// — and neither is a host object created under prefab content, so the bimap
// lookup alone silently no-ops every nested structural redo. Falls back to a
// live scan of the scene's transforms.
@(private)
_find_transform_for_undo :: proc(s: ^engine.Scene, id: engine.Local_ID) -> (engine.Handle, bool) {
	if h, ok := scene_find_transform_by_local_id(s, id); ok do return h, true
	if s == nil || id == 0 do return {}, false
	w := engine.ctx_world()
	if w == nil do return {}, false
	it := engine.pool_iterator(&w.transforms)
	for t, h in engine.pool_next(&it) {
		if t.scene != s || t.local_id != id do continue
		h := h
		h.type_key = .Transform
		return h, true
	}
	return {}, false
}

@(private)
_paste_subtree_preserve_ids :: proc(payload: []byte, parent: engine.Transform_Handle, sibling_index: int) -> engine.Transform_Handle {
	if payload == nil || len(payload) == 0 do return {}
	sf: engine.SceneFile
	if err := json.unmarshal(payload, &sf); err != nil {
		log.error(fmt.tprintf("undo: unmarshal subtree failed: %v", err))
		return {}
	}
	defer engine.scene_file_destroy(&sf)

	w := engine.ctx_world()
	parent_scene: ^engine.Scene
	if p := engine.pool_get(&w.transforms, engine.Handle(parent)); p != nil {
		parent_scene = p.scene
	}

	root_tH := engine._scene_load_as_child(&sf, parent, parent_scene)
	if root_tH == {} do return {}

	p := engine.pool_get(&w.transforms, engine.Handle(parent))
	if p != nil && sibling_index >= 0 {
		current_idx := -1
		for i in 0 ..< len(p.children) {
			if p.children[i].handle == engine.Handle(root_tH) {
				current_idx = i
				break
			}
		}
		if current_idx >= 0 && current_idx != sibling_index {
			entry := p.children[current_idx]
			ordered_remove(&p.children, current_idx)
			idx := sibling_index
			if idx > len(p.children) do idx = len(p.children)
			inject_at(&p.children, idx, entry)
		}
	}

	if engine.application_is_editor() {
		engine._scene_resolve_nested_in_subtree(root_tH)
	}

	// Components OUTSIDE the restored subtree may reference INTO it (a Tank on
	// the root pointing at a deleted-then-restored Turret) — their handles are
	// dead and only a scene-wide rebind reaches them. The loader re-registered
	// the restored lids (dead-entry repair), so the sweep binds them live.
	engine.scene_rebind_unbound_refs(parent_scene)

	return root_tH
}

@(private)
_do_add_component :: proc(v: Add_Component_Command) {
	owner_h, ok := scene_find_transform_by_local_id(_scene(v.scene), v.owner_local_id)
	if !ok do return
	tH := engine.Transform_Handle(owner_h)

	owned, ptr := engine.transform_add_comp(tH, v.type_key)
	if ptr == nil do return

	if v.payload != nil && len(v.payload) > 0 {
		tid := engine.get_typeid_by_type_key(v.type_key)
		ptr_tid, ptr_ok := engine.get_pointer_typeid_by_typeid(tid)
		if ptr_ok {
			target_ptr := ptr
			if err := json.unmarshal_any(v.payload, any{&target_ptr, ptr_tid}, json.DEFAULT_SPECIFICATION, context.allocator); err != nil {
				log.error(fmt.tprintf("undo: unmarshal component failed: %v", err))
			}
			base := cast(^engine.CompData)ptr
			base.owner = tH
			base.local_id = v.comp_local_id
			// Handles are json:"-", so the payload's Refs are rebound here, as
			// a value write does.
			if s := _scene(v.scene); s != nil {
				engine._resolve_refs_in_value(ptr, type_info_of(tid), s, nil, false, true)
			}
			engine.type_on_validate(v.type_key, ptr)
		}
	}

	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(owner_h))
	if t != nil && v.list_index >= 0 && v.list_index < len(t.components) {
		last := len(t.components) - 1
		if last != v.list_index {
			entry := t.components[last]
			ordered_remove(&t.components, last)
			inject_at(&t.components, v.list_index, entry)
		}
	}

	base := cast(^engine.CompData)ptr
	base.local_id = v.comp_local_id
	// transform_add_comp minted (and registered) a throwaway lid — the restored
	// component answers to its RECORDED lid, so point the live index at it and
	// rebind any refs that dangled while the component was gone.
	if s := _scene(v.scene); s != nil {
		engine.bimap_insert(&s.local_ids, v.comp_local_id, owned.handle)
		engine.scene_rebind_unbound_refs(s)
	}
	if t != nil {
		for i in 0 ..< len(t.components) {
			if t.components[i].handle == owned.handle {
				t.components[i].local_id = v.comp_local_id
				break
			}
		}
	}
}

@(private)
_do_reorder_components :: proc(s: ^engine.Scene, owner_local_id: engine.Local_ID, from, to: int) {
	owner_h, ok := scene_find_transform_by_local_id(s, owner_local_id)
	if !ok do return
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, owner_h)
	if t == nil do return
	if from < 0 || from >= len(t.components) do return
	if to < 0 || to >= len(t.components) do return
	if from == to do return
	entry := t.components[from]
	ordered_remove(&t.components, from)
	inject_at(&t.components, to, entry)
}
