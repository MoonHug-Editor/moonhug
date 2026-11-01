package animation_editor

// The Add Property menu of the Animation window: the owner's subtree as
// nested menus, and the procs that add a transform or property channel with
// a first key holding the current value.

import "base:runtime"
import "core:encoding/uuid"
import "core:fmt"
import "core:reflect"
import "core:strings"
import im "moonhug:external/odin-imgui"
import engine "moonhug:packages/engine"
import anim "moonhug:packages/animation"
import "moonhug:editor/inspector"

// --- Add Property ------------------------------------------------------------------------
//
// The owner's subtree as nested menus: per object the three transform
// channels, then each component with its animatable POD leaves enumerated by
// reflection (the same kinds the runtime applies — clip_property.odin).

@(private = "file") _PV_PROP_MAX_DEPTH :: 6 // object recursion cap

@(private)
_pv_add_prop_object :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, tH: engine.Transform_Handle, path: string, depth: int) {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return

	label := path == "" ? "(self)" : path
	if im.BeginMenu(fmt.ctprintf("%s##obj", label)) {
		// Rotation adds an Euler row: angles the inspector shows, that mask
		// and split like a vector. Model clips bring the quaternion rows.
		if im.MenuItem("Transform.Position") do _pv_add_channel_transform(doc, clip, path, .Position, tH)
		if im.MenuItem("Transform.Rotation") do _pv_add_channel_transform(doc, clip, path, .Euler, tH)
		if im.MenuItem("Transform.Scale") do _pv_add_channel_transform(doc, clip, path, .Scale, tH)
		for c in t.components {
			tid := engine.get_typeid_by_type_key(c.handle.type_key)
			if tid == nil do continue
			comp_name := fmt.tprintf("%v", tid)
			if dot := strings.last_index_byte(comp_name, '.'); dot >= 0 {
				comp_name = comp_name[dot + 1:]
			}
			leaves := make([dynamic]string, context.temp_allocator)
			_pv_prop_leaves(tid, "", &leaves, 0)
			if len(leaves) == 0 do continue
			im.Separator()
			if im.BeginMenu(fmt.ctprintf("%s##c%d", comp_name, c.handle.index)) {
				guid_str := uuid.to_string(engine.get_guid_by_type_key(c.handle.type_key), context.temp_allocator)
				for field in leaves {
					if im.MenuItem(fmt.ctprintf("%s", field)) {
						_pv_add_channel_property(doc, clip, path, guid_str, field, tH)
					}
				}
				im.EndMenu()
			}
		}
		im.EndMenu()
	}

	if depth >= _PV_PROP_MAX_DEPTH do return
	for child in t.children {
		ct := engine.pool_get(&w.transforms, child.handle)
		if ct == nil do continue
		child_path := path == "" ? ct.name : fmt.tprintf("%s/%s", path, ct.name)
		_pv_add_prop_object(doc, clip, engine.Transform_Handle(child.handle), child_path, depth + 1)
	}
}

// Animatable leaves of a component type as dotted field paths. Walks plain
// struct nesting the way the runtime resolver does, skipping identity
// plumbing (base) and the reference types that are not animatable (a PPtr is
// a leaf).
@(private = "file")
_pv_prop_leaves :: proc(tid: typeid, prefix: string, out: ^[dynamic]string, depth: int) {
	if depth > 4 do return
	names := reflect.struct_field_names(tid)
	types := reflect.struct_field_types(tid)
	for i in 0 ..< len(names) {
		name := names[i]
		if name == "base" do continue
		ftid := types[i].id
		if ftid == typeid_of(engine.Ref) || ftid == typeid_of(engine.Ref_Local) || ftid == typeid_of(engine.Owned) {
			continue
		}
		full := prefix == "" ? name : fmt.tprintf("%s.%s", prefix, name)
		if _, ok := anim._prop_kind_of(ftid); ok {
			append(out, strings.clone(full, context.temp_allocator))
			continue
		}
		ti := runtime.type_info_base(type_info_of(ftid))
		if _, is_struct := ti.variant.(runtime.Type_Info_Struct); is_struct {
			_pv_prop_leaves(ftid, full, out, depth + 1)
		}
	}
}

@(private)
_pv_add_channel_transform :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, target: string, path: anim.Animation_Path, tH: engine.Transform_Handle) {
	if doc == nil do return // read-only clip
	for &c in clip.channels {
		if !anim.animation_channel_is_property(&c) && c.target == target && c.path == path do return
	}
	w := engine.ctx_world()
	v: [4]f32
	if t := engine.pool_get(&w.transforms, engine.Handle(tH)); t != nil {
		switch path {
		case .Position: v.xyz = t.position
		case .Rotation: v = t.rotation
		case .Scale:    v.xyz = t.scale
		case .Euler:    v.xyz = engine.quat_to_euler_xyz(t.rotation)
		}
	}
	// The row's strings live in the document.
	_pv_append_channel(doc, clip, anim.Animation_Channel{
		target = strings.clone(target, inspector.doc_alloc()),
		path   = path,
	}, anim.Channel_Value(v))
}

@(private)
_pv_add_channel_property :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, target: string, guid_str: string, field: string, tH: engine.Transform_Handle) {
	if doc == nil do return // read-only clip
	for &c in clip.channels {
		if c.target == target && c.component == guid_str && c.field == field do return
	}
	// First key holds the field's CURRENT value, so adding a property never
	// visibly changes the object. The row's kind follows the field's: floats,
	// ints, references or strings (a string is cloned into the row).
	v: anim.Channel_Value = [4]f32{}
	if ptr, kind, leaf, ok := anim._prop_locate(tH, guid_str, field); ok {
		v = anim._prop_read_value(ptr, kind, leaf)
	}
	// The row's strings live in the document.
	a := inspector.doc_alloc()
	_pv_append_channel(doc, clip, anim.Animation_Channel{
		target    = strings.clone(target, a),
		component = strings.clone(guid_str, a),
		field     = strings.clone(field, a),
	}, v)
}

@(private = "file")
_pv_append_channel :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, ch: anim.Animation_Channel, v: anim.Channel_Value) {
	if doc == nil do return // read-only clip
	ch := ch
	_pv_edit_begin(doc)
	{
		// The row's key arrays live in the document. The undo session keeps
		// the caller's allocator.
		context.allocator = inspector.doc_alloc()
		ch.times = make([dynamic]f32)
		ch.values = anim.animation_channel_values_make(v)
		anim.animation_channel_insert_key(&ch, 0, 0, v)
		append(&clip.channels, ch)
	}
	_pv_sel_set(len(clip.channels) - 1, 0)
	_pv_collapse_clear(ch.target) // the new row shows, selected
	_pv_edit_commit(doc)
}
