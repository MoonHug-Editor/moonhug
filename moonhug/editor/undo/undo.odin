package undo

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "base:builtin"
import engine "../../engine"
import "../../engine/log"

MAX_ENTRIES :: 32

Owner_Kind :: enum {
	None,
	Pooled,
	Raw,
}

Property_Target :: struct {
	kind:      Owner_Kind,
	scene:     ^engine.Scene,
	local_id:  engine.Local_ID,
	handle:    engine.Handle,
	offset:    u32,
	type_id:   typeid,
	raw_ptr:   rawptr,
}

Value_Command :: struct {
	target:   Property_Target,
	old_json: []byte,
	new_json: []byte,
}

Reparent_Command :: struct {
	scene:                ^engine.Scene,
	node_local_id:        engine.Local_ID,
	old_parent_local_id:  engine.Local_ID,
	new_parent_local_id:  engine.Local_ID,
	old_index:            int,
	new_index:            int,
}

Create_Subtree_Command :: struct {
	scene:               ^engine.Scene,
	parent_local_id:     engine.Local_ID,
	root_local_id:       engine.Local_ID,
	sibling_index:       int,
	payload:             []byte,
}

Delete_Subtree_Command :: struct {
	scene:               ^engine.Scene,
	parent_local_id:     engine.Local_ID,
	root_local_id:       engine.Local_ID,
	sibling_index:       int,
	payload:             []byte,
}

Add_Component_Command :: struct {
	scene:               ^engine.Scene,
	owner_local_id:      engine.Local_ID,
	type_key:            engine.TypeKey,
	comp_local_id:       engine.Local_ID,
	payload:             []byte,
	list_index:          int,
}

Remove_Component_Command :: struct {
	scene:               ^engine.Scene,
	owner_local_id:      engine.Local_ID,
	type_key:            engine.TypeKey,
	comp_local_id:       engine.Local_ID,
	payload:             []byte,
	list_index:          int,
}

Reorder_Components_Command :: struct {
	scene:               ^engine.Scene,
	owner_local_id:      engine.Local_ID,
	old_index:           int,
	new_index:           int,
}

Structural_Command :: union {
	Reparent_Command,
	Create_Subtree_Command,
	Delete_Subtree_Command,
	Add_Component_Command,
	Remove_Component_Command,
	Reorder_Components_Command,
}

Group_Command :: struct {
	subs: [dynamic]Command,
}

Command :: union {
	Value_Command,
	Structural_Command,
	Group_Command,
}

Entry :: struct {
	label: string,
	cmd:   Command,
}

Undo_Stack :: struct {
	items:      [dynamic]Entry,
	top:        int,
	txn_stack:  [dynamic]Group_Command,
	recording:  bool,
	applying:   bool,
}

init :: proc(s: ^Undo_Stack) {
	s.items = make([dynamic]Entry)
	s.txn_stack = make([dynamic]Group_Command)
	s.recording = true
}

clear :: proc(s: ^Undo_Stack) {
	if s == nil do return
	for &e in s.items {
		_entry_destroy(&e)
	}
	builtin.clear(&s.items)
	for &g in s.txn_stack {
		_group_destroy(&g)
	}
	builtin.clear(&s.txn_stack)
	s.top = 0
}

destroy :: proc(s: ^Undo_Stack) {
	if s == nil do return
	clear(s)
	delete(s.items)
	delete(s.txn_stack)
	s.items = {}
	s.txn_stack = {}
}

set_recording :: proc(s: ^Undo_Stack, on: bool) {
	s.recording = on
}

is_applying :: proc(s: ^Undo_Stack) -> bool {
	return s != nil && s.applying
}

get :: proc() -> ^Undo_Stack {
	uc := engine.ctx_get()
	if uc == nil do return nil
	return (^Undo_Stack)(uc.undo)
}

install :: proc(s: ^Undo_Stack) {
	uc := engine.ctx_get()
	if uc == nil do return
	uc.undo = rawptr(s)
}

push :: proc(s: ^Undo_Stack, cmd: Command, label := "") {
	if s == nil do return
	if !s.recording || s.applying do return

	if len(s.txn_stack) > 0 {
		top_txn := &s.txn_stack[len(s.txn_stack) - 1]
		append(&top_txn.subs, cmd)
		return
	}

	for i := len(s.items) - 1; i >= s.top; i -= 1 {
		e := &s.items[i]
		_entry_destroy(e)
		ordered_remove(&s.items, i)
	}

	for len(s.items) >= MAX_ENTRIES {
		e := &s.items[0]
		_entry_destroy(e)
		ordered_remove(&s.items, 0)
		if s.top > 0 do s.top -= 1
	}

	effective_label := label
	if effective_label == "" {
		effective_label = default_label(cmd)
	}
	append(&s.items, Entry{label = effective_label, cmd = cmd})
	s.top = len(s.items)
}

jump_to :: proc(s: ^Undo_Stack, target_top: int) -> bool {
	if s == nil do return false
	if target_top < 0 || target_top > len(s.items) do return false
	for s.top > target_top {
		if !apply_undo(s) do return false
	}
	for s.top < target_top {
		if !apply_redo(s) do return false
	}
	return true
}

default_label :: proc(cmd: Command) -> string {
	switch v in cmd {
	case Value_Command:
		switch v.target.kind {
		case .None:   return "Edit Value"
		case .Pooled: return v.target.handle.type_key == .Transform ? "Edit Transform" : "Edit Component"
		case .Raw:    return "Edit"
		}
		return "Edit Value"
	case Structural_Command:
		switch sv in v {
		case Reparent_Command:           return "Reparent"
		case Create_Subtree_Command:     return "Create"
		case Delete_Subtree_Command:     return "Delete"
		case Add_Component_Command:      return "Add Component"
		case Remove_Component_Command:   return "Remove Component"
		case Reorder_Components_Command: return "Reorder Components"
		}
		return "Structural"
	case Group_Command:
		return "Group"
	}
	return ""
}

begin_group_command :: proc(s: ^Undo_Stack, label := "") {
	if s == nil do return
	if !s.recording || s.applying do return
	append(&s.txn_stack, Group_Command{subs = make([dynamic]Command)})
}

abort_group_command :: proc(s: ^Undo_Stack) {
	if s == nil do return
	if len(s.txn_stack) == 0 do return
	grp := s.txn_stack[len(s.txn_stack) - 1]
	pop(&s.txn_stack)
	_group_destroy(&grp)
}

end_group_command :: proc(s: ^Undo_Stack, label := "") {
	if s == nil do return
	if len(s.txn_stack) == 0 do return
	grp := s.txn_stack[len(s.txn_stack) - 1]
	pop(&s.txn_stack)

	if len(grp.subs) == 0 {
		delete(grp.subs)
		return
	}

	if len(s.txn_stack) > 0 {
		outer := &s.txn_stack[len(s.txn_stack) - 1]
		append(&outer.subs, Command(grp))
		return
	}

	for i := len(s.items) - 1; i >= s.top; i -= 1 {
		e := &s.items[i]
		_entry_destroy(e)
		ordered_remove(&s.items, i)
	}
	for len(s.items) >= MAX_ENTRIES {
		e := &s.items[0]
		_entry_destroy(e)
		ordered_remove(&s.items, 0)
		if s.top > 0 do s.top -= 1
	}
	append(&s.items, Entry{label = label, cmd = Command(grp)})
	s.top = len(s.items)
}

can_undo :: proc(s: ^Undo_Stack) -> bool {
	return s != nil && s.top > 0
}

entries :: proc(s: ^Undo_Stack) -> []Entry {
	if s == nil do return nil
	return s.items[:]
}

top_index :: proc(s: ^Undo_Stack) -> int {
	if s == nil do return 0
	return s.top
}

can_redo :: proc(s: ^Undo_Stack) -> bool {
	return s != nil && s.top < len(s.items)
}

apply_undo :: proc(s: ^Undo_Stack) -> bool {
	if !can_undo(s) do return false
	s.applying = true
	defer s.applying = false
	s.top -= 1
	cmd := &s.items[s.top].cmd
	_revert_command(cmd)
	return true
}

apply_redo :: proc(s: ^Undo_Stack) -> bool {
	if !can_redo(s) do return false
	s.applying = true
	defer s.applying = false
	cmd := &s.items[s.top].cmd
	_apply_command(cmd)
	s.top += 1
	return true
}

@(private)
_apply_command :: proc(cmd: ^Command) {
	switch v in cmd {
	case Value_Command:
		_value_apply(v, v.new_json)
	case Structural_Command:
		_structural_apply(v)
	case Group_Command:
		for i in 0 ..< len(v.subs) {
			_apply_command(&v.subs[i])
		}
	}
}

@(private)
_revert_command :: proc(cmd: ^Command) {
	switch v in cmd {
	case Value_Command:
		_value_apply(v, v.old_json)
	case Structural_Command:
		_structural_revert(v)
	case Group_Command:
		for i := len(v.subs) - 1; i >= 0; i -= 1 {
			_revert_command(&v.subs[i])
		}
	}
}

@(private)
_entry_destroy :: proc(e: ^Entry) {
	_command_destroy(&e.cmd)
}

@(private)
_command_destroy :: proc(cmd: ^Command) {
	switch v in cmd {
	case Value_Command:
		vc := v
		delete(vc.old_json)
		delete(vc.new_json)
	case Structural_Command:
		sc := v
		_structural_destroy(&sc)
	case Group_Command:
		gc := v
		_group_destroy(&gc)
	}
}

@(private)
_group_destroy :: proc(g: ^Group_Command) {
	for i in 0 ..< len(g.subs) {
		_command_destroy(&g.subs[i])
	}
	delete(g.subs)
}

@(private)
_structural_destroy :: proc(sc: ^Structural_Command) {
	switch v in sc {
	case Reparent_Command:
	case Create_Subtree_Command:
		if v.payload != nil do delete(v.payload)
	case Delete_Subtree_Command:
		if v.payload != nil do delete(v.payload)
	case Add_Component_Command:
		if v.payload != nil do delete(v.payload)
	case Remove_Component_Command:
		if v.payload != nil do delete(v.payload)
	case Reorder_Components_Command:
	}
}

resolve_target_ptr :: proc(t: Property_Target) -> rawptr {
	switch t.kind {
	case .None:
		return nil
	case .Raw:
		if t.raw_ptr == nil do return nil
		return rawptr(uintptr(t.raw_ptr) + uintptr(t.offset))
	case .Pooled:
		base, _, ok := resolve_pooled_base(t)
		if !ok do return nil
		return rawptr(uintptr(base) + uintptr(t.offset))
	}
	return nil
}

resolve_pooled_base :: proc(t: Property_Target) -> (rawptr, engine.Handle, bool) {
	if t.kind != .Pooled do return nil, {}, false
	w := engine.ctx_world()
	if w == nil do return nil, {}, false
	h := t.handle
	if !engine.world_pool_valid(w, h) {
		if t.scene == nil || t.local_id == 0 do return nil, {}, false
		resolved: engine.Handle
		ok: bool
		if h.type_key == .Transform {
			resolved, ok = scene_find_transform_by_local_id(t.scene, t.local_id)
		} else {
			resolved, ok = scene_find_component_by_local_id(t.scene, t.local_id)
		}
		if !ok do return nil, {}, false
		h = resolved
	}
	base := engine.world_pool_get(w, h)
	if base == nil do return nil, h, false
	return base, h, true
}

resolve_component_base :: proc(t: Property_Target) -> (rawptr, engine.Handle, bool) {
	if t.kind != .Pooled || t.handle.type_key == .Transform do return nil, {}, false
	return resolve_pooled_base(t)
}

make_pooled_target :: proc(h: engine.Handle, offset: uintptr, tid: typeid) -> Property_Target {
	w := engine.ctx_world()
	scene: ^engine.Scene
	lid: engine.Local_ID
	if h.type_key == .Transform {
		if t := engine.pool_get(&w.transforms, h); t != nil {
			scene = t.scene
			lid = t.local_id
		}
	} else {
		if base := engine.world_pool_get(w, h); base != nil {
			cbase := cast(^engine.CompData)base
			lid = cbase.local_id
			if t := engine.pool_get(&w.transforms, engine.Handle(cbase.owner)); t != nil {
				scene = t.scene
			}
		}
	}
	return Property_Target{
		kind = .Pooled,
		scene = scene,
		local_id = lid,
		handle = h,
		offset = u32(offset),
		type_id = tid,
	}
}

make_transform_target :: proc(tH: engine.Transform_Handle, offset: uintptr, tid: typeid) -> Property_Target {
	return make_pooled_target(engine.Handle(tH), offset, tid)
}

make_component_target :: proc(comp_handle: engine.Handle, offset: uintptr, tid: typeid) -> Property_Target {
	return make_pooled_target(comp_handle, offset, tid)
}

make_raw_target :: proc(ptr: rawptr, offset: uintptr, tid: typeid) -> Property_Target {
	return Property_Target{
		kind = .Raw,
		raw_ptr = ptr,
		offset = u32(offset),
		type_id = tid,
	}
}

capture_json :: proc(ptr: rawptr, tid: typeid) -> []byte {
	if ptr == nil || tid == nil do return nil
	opts := json.Marshal_Options{spec = .JSON, pretty = false}
	data, err := json.marshal(any{ptr, tid}, opts)
	if err != nil {
		log.error(fmt.tprintf("undo: marshal failed for %v: %v", tid, err))
		return nil
	}
	return data
}

push_value :: proc(s: ^Undo_Stack, t: Property_Target, old_json, new_json: []byte, label := "") {
	if s == nil do return
	if !s.recording || s.applying {
		if old_json != nil do delete(old_json)
		if new_json != nil do delete(new_json)
		return
	}
	if old_json == nil || new_json == nil {
		if old_json != nil do delete(old_json)
		if new_json != nil do delete(new_json)
		return
	}
	if slice.equal(old_json, new_json) {
		delete(old_json)
		delete(new_json)
		return
	}
	cmd: Value_Command = {target = t, old_json = old_json, new_json = new_json}
	push(s, Command(cmd), label)
}

@(private)
_value_apply :: proc(vc: Value_Command, json_bytes: []byte) {
	ptr := resolve_target_ptr(vc.target)
	if ptr == nil {
		log.error(fmt.tprintf("undo: failed to resolve target for value command (tid=%v)", vc.target.type_id))
		return
	}
	ptr_tid, ok := engine.get_pointer_typeid_by_typeid(vc.target.type_id)
	if !ok {
		log.error(fmt.tprintf("undo: no pointer typeid registered for %v — call engine.register_pointer_type during init", vc.target.type_id))
		return
	}
	target_ptr := ptr
	target_any := any{data = &target_ptr, id = ptr_tid}
	if err := json.unmarshal_any(json_bytes, target_any, json.DEFAULT_SPECIFICATION, context.allocator); err != nil {
		log.error(fmt.tprintf("undo: unmarshal failed (tid=%v): %v", vc.target.type_id, err))
		return
	}

	if vc.target.kind == .Pooled && vc.target.handle.type_key != .Transform {
		if base, h, ok := resolve_pooled_base(vc.target); ok {
			engine.component_on_validate(h.type_key, base)
		}
	}
}

scene_find_transform_by_local_id :: proc(s: ^engine.Scene, id: engine.Local_ID) -> (engine.Handle, bool) {
	if s == nil || id == 0 do return {}, false
	w := engine.ctx_world()
	if w == nil do return {}, false
	for i in 0 ..< len(w.transforms.slots) {
		slot := &w.transforms.slots[i]
		if !slot.alive do continue
		if slot.data.scene != s do continue
		if slot.data.nested_owned do continue
		if slot.data.local_id == id {
			return engine.Handle{index = u32(i), generation = slot.generation, type_key = .Transform}, true
		}
	}
	return {}, false
}

scene_find_component_by_local_id :: proc(s: ^engine.Scene, id: engine.Local_ID) -> (engine.Handle, bool) {
	if s == nil || id == 0 do return {}, false
	w := engine.ctx_world()
	if w == nil do return {}, false
	for i in 0 ..< len(w.transforms.slots) {
		slot := &w.transforms.slots[i]
		if !slot.alive do continue
		if slot.data.scene != s do continue
		if slot.data.nested_owned do continue
		for c in slot.data.components {
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

@(private)
_structural_apply :: proc(sc: Structural_Command) {
	switch v in sc {
	case Reparent_Command:
		_do_reparent(v.scene, v.node_local_id, v.new_parent_local_id, v.new_index)
	case Create_Subtree_Command:
		_do_create_subtree(v)
	case Delete_Subtree_Command:
		_do_delete_subtree(v)
	case Add_Component_Command:
		_do_add_component(v)
	case Remove_Component_Command:
		_do_remove_component(v)
	case Reorder_Components_Command:
		_do_reorder_components(v.scene, v.owner_local_id, v.old_index, v.new_index)
	}
}

@(private)
_structural_revert :: proc(sc: Structural_Command) {
	switch v in sc {
	case Reparent_Command:
		_do_reparent(v.scene, v.node_local_id, v.old_parent_local_id, v.old_index)
	case Create_Subtree_Command:
		_undo_create_subtree(v)
	case Delete_Subtree_Command:
		_undo_delete_subtree(v)
	case Add_Component_Command:
		_undo_add_component(v)
	case Remove_Component_Command:
		_undo_remove_component(v)
	case Reorder_Components_Command:
		_do_reorder_components(v.scene, v.owner_local_id, v.new_index, v.old_index)
	}
}

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

@(private)
_do_create_subtree :: proc(v: Create_Subtree_Command) {
	parent_h, ok := scene_find_transform_by_local_id(v.scene, v.parent_local_id)
	if !ok do return
	_paste_subtree_preserve_ids(v.payload, engine.Transform_Handle(parent_h), v.sibling_index)
}

@(private)
_undo_create_subtree :: proc(v: Create_Subtree_Command) {
	node_h, ok := scene_find_transform_by_local_id(v.scene, v.root_local_id)
	if !ok do return
	engine.transform_destroy(engine.Transform_Handle(node_h))
}

@(private)
_do_delete_subtree :: proc(v: Delete_Subtree_Command) {
	node_h, ok := scene_find_transform_by_local_id(v.scene, v.root_local_id)
	if !ok do return
	engine.transform_destroy(engine.Transform_Handle(node_h))
}

@(private)
_undo_delete_subtree :: proc(v: Delete_Subtree_Command) {
	parent_h, ok := scene_find_transform_by_local_id(v.scene, v.parent_local_id)
	if !ok do return
	_paste_subtree_preserve_ids(v.payload, engine.Transform_Handle(parent_h), v.sibling_index)
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

	if parent_scene != nil && sf.next_local_id > parent_scene.next_local_id {
		parent_scene.next_local_id = sf.next_local_id
	}

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

	if !engine.ctx_get().is_playmode {
		engine._scene_resolve_nested_in_subtree(root_tH)
	}
	return root_tH
}

@(private)
_do_add_component :: proc(v: Add_Component_Command) {
	owner_h, ok := scene_find_transform_by_local_id(v.scene, v.owner_local_id)
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
			engine.component_on_validate(v.type_key, ptr)
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
_undo_add_component :: proc(v: Add_Component_Command) {
	comp_h, ok := scene_find_component_by_local_id(v.scene, v.comp_local_id)
	if !ok do return
	owner_h, oh_ok := scene_find_transform_by_local_id(v.scene, v.owner_local_id)
	if !oh_ok do return
	engine.transform_remove_comp(engine.Transform_Handle(owner_h), comp_h)
}

@(private)
_do_remove_component :: proc(v: Remove_Component_Command) {
	comp_h, ok := scene_find_component_by_local_id(v.scene, v.comp_local_id)
	if !ok do return
	owner_h, oh_ok := scene_find_transform_by_local_id(v.scene, v.owner_local_id)
	if !oh_ok do return
	engine.transform_remove_comp(engine.Transform_Handle(owner_h), comp_h)
}

@(private)
_undo_remove_component :: proc(v: Remove_Component_Command) {
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

capture_transform_subtree :: proc(tH: engine.Transform_Handle) -> []byte {
	return engine.scene_copy_subtree(tH)
}

capture_component_json :: proc(ptr: rawptr, tid: typeid) -> []byte {
	return capture_json(ptr, tid)
}
