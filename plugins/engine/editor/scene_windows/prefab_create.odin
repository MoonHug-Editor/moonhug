package scene_windows

// GameObject > Create Prefab: each selected object becomes a scene file of
// its own, a prefab, and the object becomes an instance of that file, in its
// place. One undo step: undo puts the objects back, the files stay.
//
// - The file is written in the Project window's open folder, named after the
//   object. Its root sits at the file's origin: the instance keeps the
//   object's place.
// - References between the objects of the subtree stay in the prefab.
// - References from the rest of the scene to them move to the instance's
//   objects.
// - References from them to the rest of the scene cannot live in an asset:
//   the file has them empty, and the instance keeps them as overrides.
// - Prefab instances inside the subtree stay prefab instances in the file.
// - Not for a scene root, a prefab instance or what is inside one, nor while
//   the game runs.

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:strings"
import "moonhug:editor/inspector"
import "moonhug:editor/keymap"
import "moonhug:editor/session"
import "moonhug:libs/log"
import "moonhug:packages/engine"
import asset_pipeline "moonhug:editor/assets"
import undo "moonhug:packages/engine/editor/undo"

@(menu_item={path="GameObject/Create Prefab", order=-97, enabled=_can_create_prefab, help="Saves each selected object as a prefab in the Project window's open folder and puts an instance of it in its place"})
create_prefab_menu :: proc() {
	if !_can_create_prefab() do return
	dir := session.project_dir()
	g := undo.group_begin("Create Prefab")
	defer undo.group_end(&g)
	undo.record_selection_snapshot()
	made := make([dynamic]engine.Transform_Handle, context.temp_allocator)
	for h in session.top_level() {
		if _prefab_refusal(h) != "" do continue
		t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(h))
		path := _prefab_free_path(dir, t.name)
		if inst := prefab_create(h, path); inst != {} do append(&made, inst)
	}
	if len(made) == 0 do return
	undo.group_commit(&g)
	session.select_clear()
	for inst in made do session.select_add(inst)
}

// Enabled when some selected object can become a prefab, with the reason
// otherwise.
_can_create_prefab :: proc() -> bool {
	if engine.game_running() do return keymap.disabled("Stop the game first")
	if session.project_dir() == "" do return keymap.disabled("The Project window has no open folder")
	targets := session.top_level()
	if len(targets) == 0 do return keymap.disabled("Nothing is selected")
	why := ""
	for h in targets {
		why = _prefab_refusal(h)
		if why == "" do return true
	}
	return keymap.disabled(why)
}

// Why `h` cannot become a prefab, "" when it can.
_prefab_refusal :: proc(h: engine.Transform_Handle) -> string {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(h))
	if t == nil || t.scene == nil do return "Nothing is selected"
	if _hierarchy_handle_is_root(h) do return "A scene root cannot become a prefab"
	if engine.scene_find_nested_scene_for_host(t.scene, h) != nil do return "It is a prefab instance already"
	if _hierarchy_handle_is_nested(h) do return "Objects inside a prefab instance cannot become a prefab"
	if pt := engine.pool_get(&w.transforms, t.parent.handle); pt != nil && engine.scene_find_nested_scene_for_host(pt.scene, engine.Transform_Handle(t.parent.handle)) != nil {
		return "Objects added to a prefab instance cannot become a prefab"
	}
	return ""
}

// `dir`/<name>.scene, or <name> N.scene when taken. Characters a file name
// cannot hold become _.
_prefab_free_path :: proc(dir, name: string) -> string {
	stem := strings.trim_space(name)
	if stem == "" do stem = "Prefab"
	b := strings.builder_make(context.temp_allocator)
	for r in stem {
		switch r {
		case '/', '\\', ':', '*', '?', '"', '<', '>', '|': strings.write_rune(&b, '_')
		case: strings.write_rune(&b, r)
		}
	}
	stem = strings.to_string(b)
	path, _ := filepath.join({dir, fmt.tprintf("%s.scene", stem)}, context.temp_allocator)
	for i := 1; os.exists(path); i += 1 {
		path, _ = filepath.join({dir, fmt.tprintf("%s %d.scene", stem, i)}, context.temp_allocator)
	}
	return path
}

// Saves the subtree at `src` as a prefab at `path` and puts an instance of
// it in its place, recorded in the open undo group. The instance, {} when
// nothing changed.
prefab_create :: proc(src: engine.Transform_Handle, path: string) -> engine.Transform_Handle {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(src))
	if t == nil || t.scene == nil do return {}
	scene := t.scene
	parent := engine.Transform_Handle(t.parent.handle)
	index := engine.transform_get_sibling_index(src)
	place := t.position

	// Every object and component of the subtree, by id: what the prefab holds.
	inside := make(map[engine.Local_ID]bool, context.temp_allocator)
	inside_handles := make(map[engine.Handle]bool, context.temp_allocator)
	_subtree_ids(w, src, &inside, &inside_handles)

	if !_prefab_write(src, path, &inside) {
		log.errorf("[Prefab] could not write %s", path)
		return {}
	}
	asset_pipeline.asset_db_refresh()
	raw, known := engine.asset_db_get_guid(path)
	if !known {
		log.errorf("[Prefab] %s is not an asset after it was written", path)
		return {}
	}
	inst := engine.scene_instantiate_guid_nested(engine.Asset_GUID(raw), parent)
	if inst == {} {
		log.errorf("[Prefab] %s did not instantiate", path)
		return {}
	}

	// Each object and component of the subtree, and its counterpart in the
	// instance: the instance is built from a file written from the subtree,
	// so the two trees have one shape.
	pairs := make(map[engine.Handle]engine.Handle, context.temp_allocator)
	moved := make(map[engine.Local_ID]engine.Local_ID, context.temp_allocator)
	_pair_trees(w, src, inst, &pairs, &moved)

	// What to write once the instance stands in the subtree's place, read
	// now while the subtree is there: the instance's own references out of
	// the subtree, and the scene's references into it.
	own := make([dynamic]_Ref_Write, context.temp_allocator)
	_collect_writes_from_subtree(w, src, &inside, &pairs, &moved, &own)
	others := make([dynamic]_Ref_Write, context.temp_allocator)
	_collect_writes_into_subtree(w, scene, &inside, &inside_handles, &moved, &others)

	undo.record_delete(src)
	_place_instance(w, inst, parent, index, place)
	// The instance's references out of the prefab are overrides in its
	// record, before the create captures it: redo builds the instance again
	// from that record, and an undo value change could not find a prefab
	// object of the rebuilt instance.
	for wr in own do _write_override(scene, wr)
	undo.record_create(inst, parent)
	// The scene's references are value changes of objects the redo keeps.
	for wr in others {
		p, ok := inspector.inspect_comp(wr.comp)
		if !ok do continue
		fp, err := inspector.property(p, wr.path)
		if err != .None do continue
		if done, why := inspector.property_set_json(fp, wr.json, "Create Prefab"); !done {
			log.warningf("[Prefab] a reference at %s was not moved to the instance: %s", wr.path, why)
		}
	}
	return inst
}

// Sets a field of a component of the instance and records it as an
// override of the instance, with no undo step of its own.
@(private = "file")
_write_override :: proc(scene: ^engine.Scene, wr: _Ref_Write) {
	w := engine.ctx_world()
	p, ok := inspector.inspect_comp(wr.comp)
	if !ok do return
	fp, err := inspector.property(p, wr.path)
	if err != .None do return
	if !undo.write_json_value(fp.ptr, fp.tid, wr.json, {id = scene.session_id}, quiet = true) {
		log.warningf("[Prefab] a reference at %s was not kept", wr.path)
		return
	}
	base := cast(^engine.CompData)engine.world_pool_get(w, wr.comp)
	if base == nil do return
	host := engine.transform_immediate_nested_host(base.owner)
	if _, recorded := engine.nested_scene_record_override_for_host(scene, host, base.local_id, wr.path, fp.ptr, fp.tid); !recorded {
		log.warningf("[Prefab] a reference at %s is not an override of the instance", wr.path)
	}
}

// One field of a component to set: the reference it holds, as JSON.
@(private = "file")
_Ref_Write :: struct {
	comp: engine.Handle,
	path: string,
	json: []byte,
}

// A transform handle as a key: the pool's iterator gives no type key.
@(private = "file")
_transform_key :: proc(h: engine.Handle) -> engine.Handle {
	k := h
	k.type_key = .Transform
	return k
}

// The ids of the objects and components of the subtree at `tH`, prefab
// content of instances inside it included, and their handles.
@(private = "file")
_subtree_ids :: proc(w: ^engine.World, tH: engine.Transform_Handle, ids: ^map[engine.Local_ID]bool, handles: ^map[engine.Handle]bool) {
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return
	ids[t.local_id] = true
	handles[_transform_key(engine.Handle(tH))] = true
	for c in t.components {
		ids[c.local_id] = true
		handles[c.handle] = true
	}
	for c in t.children do _subtree_ids(w, engine.Transform_Handle(c.handle), ids, handles)
}

// Writes the subtree at `src` as a scene file: loaded into a scene of its
// own with its ids, its root at the origin, its references out of the
// subtree emptied, and saved the way any scene is.
@(private = "file")
_prefab_write :: proc(src: engine.Transform_Handle, path: string, inside: ^map[engine.Local_ID]bool) -> bool {
	data := engine.scene_copy_subtree(src)
	if data == nil do return false
	defer delete(data)
	sf: engine.SceneFile
	if engine.scene_file_unmarshal(data, &sf) != nil do return false
	defer engine.scene_file_destroy(&sf)
	for &t in sf.transforms do if t.local_id == sf.root {
		t.parent = {}
		t.position = {}
	}

	prev := engine.sm_scene_get_active()
	s := engine.scene_new()
	engine.sm_scene_set_active(s)
	// Last in, first out: the scene goes, then the active one comes back.
	defer engine.sm_scene_set_active(prev)
	defer engine.sm_scene_unload(s)
	root := engine._scene_load_as_child(&sf, {}, s)
	if root == {} do return false
	engine.scene_set_root(s, root)
	engine._scene_resolve_nested_in_subtree(root)

	w := engine.ctx_world()
	it := engine.pool_iterator(&w.transforms)
	for ot, _ in engine.pool_next(&it) {
		if ot.scene != s || ot.nested_owned do continue
		for c in ot.components {
			ptr := engine.world_pool_get(w, c.handle)
			tid := engine.get_typeid_by_type_key(c.handle.type_key)
			if ptr == nil || tid == nil do continue
			_clear_refs_out(ptr, type_info_of(tid), inside)
		}
	}
	return engine.scene_save(s, path)
}

// Moves the instance to the subtree's place: its sibling index and position.
@(private = "file")
_place_instance :: proc(w: ^engine.World, inst, parent: engine.Transform_Handle, index: int, place: [3]f32) {
	if it := engine.pool_get(&w.transforms, engine.Handle(inst)); it != nil do it.position = place
	pt := engine.pool_get(&w.transforms, engine.Handle(parent))
	if pt == nil || index < 0 do return
	at := -1
	for c, i in pt.children do if c.handle == engine.Handle(inst) do at = i
	if at < 0 || at == index do return
	entry := pt.children[at]
	ordered_remove(&pt.children, at)
	inject_at(&pt.children, min(index, len(pt.children)), entry)
}

// Pairs the subtree `old` with the instance `new`: object by object in
// child order, component by component in list order. `moved` maps each old
// id to its counterpart's.
@(private = "file")
_pair_trees :: proc(w: ^engine.World, old, new: engine.Transform_Handle, pairs: ^map[engine.Handle]engine.Handle, moved: ^map[engine.Local_ID]engine.Local_ID) {
	ot := engine.pool_get(&w.transforms, engine.Handle(old))
	nt := engine.pool_get(&w.transforms, engine.Handle(new))
	if ot == nil || nt == nil do return
	pairs[engine.Handle(old)] = engine.Handle(new)
	moved[ot.local_id] = nt.local_id
	if len(ot.components) != len(nt.components) || len(ot.children) != len(nt.children) {
		log.errorf("[Prefab] the instance of %q does not match its objects: references to it may be lost", ot.name)
	}
	for i in 0 ..< min(len(ot.components), len(nt.components)) {
		oc, nc := ot.components[i], nt.components[i]
		if oc.handle.type_key != nc.handle.type_key do continue
		pairs[oc.handle] = nc.handle
		moved[oc.local_id] = nc.local_id
	}
	for i in 0 ..< min(len(ot.children), len(nt.children)) {
		_pair_trees(w, engine.Transform_Handle(ot.children[i].handle), engine.Transform_Handle(nt.children[i].handle), pairs, moved)
	}
}

// The references of the subtree's own components out of it, as writes on
// the instance's counterparts: the prefab has them empty, so the instance
// keeps them as overrides. A field holding references into the subtree too
// gets them moved to the instance.
@(private = "file")
_collect_writes_from_subtree :: proc(w: ^engine.World, tH: engine.Transform_Handle, inside: ^map[engine.Local_ID]bool, pairs: ^map[engine.Handle]engine.Handle, moved: ^map[engine.Local_ID]engine.Local_ID, out: ^[dynamic]_Ref_Write) {
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return
	// Prefab content of an instance inside keeps what its own prefab and
	// overrides say: the file holds those.
	if !t.nested_owned {
		for c in t.components {
			counterpart, paired := pairs[c.handle]
			if !paired do continue
			if base := cast(^engine.CompData)engine.world_pool_get(w, c.handle); base == nil || base.nested_owned do continue
			_collect_writes(w, c.handle, counterpart, inside, false, moved, out)
		}
	}
	for c in t.children do _collect_writes_from_subtree(w, engine.Transform_Handle(c.handle), inside, pairs, moved, out)
}

// The references of the scene's other components into the subtree, as
// writes that move them to the instance.
@(private = "file")
_collect_writes_into_subtree :: proc(w: ^engine.World, scene: ^engine.Scene, inside: ^map[engine.Local_ID]bool, inside_handles: ^map[engine.Handle]bool, moved: ^map[engine.Local_ID]engine.Local_ID, out: ^[dynamic]_Ref_Write) {
	it := engine.pool_iterator(&w.transforms)
	for t, h in engine.pool_next(&it) {
		if t.scene != scene || _transform_key(h) in inside_handles do continue
		for c in t.components do _collect_writes(w, c.handle, c.handle, inside, true, moved, out)
	}
}

// The writes for the component `from`, applied to `to`: one per field whose
// references name ids of `inside` (into = true) or ids out of it (into =
// false), its value with its references moved through `moved`.
@(private = "file")
_collect_writes :: proc(w: ^engine.World, from, to: engine.Handle, inside: ^map[engine.Local_ID]bool, into: bool, moved: ^map[engine.Local_ID]engine.Local_ID, out: ^[dynamic]_Ref_Write) {
	ptr := engine.world_pool_get(w, from)
	tid := engine.get_typeid_by_type_key(from.type_key)
	if ptr == nil || tid == nil do return
	paths := make([dynamic]string, context.temp_allocator)
	_ref_fields(ptr, type_info_of(tid), "", inside, into, &paths)
	if len(paths) == 0 do return
	p, ok := inspector.inspect_comp(from)
	if !ok do return
	for path in paths {
		fp, err := inspector.property(p, path)
		if err != .None do continue
		value := _moved_json(fp.ptr, fp.tid, moved)
		if value == nil do continue
		append(out, _Ref_Write{comp = to, path = path, json = value})
	}
}

// The JSON of the value at `ptr` with its scene references moved through
// `moved`, from a copy: the value itself does not change. Temp-allocated.
@(private = "file")
_moved_json :: proc(ptr: rawptr, tid: typeid, moved: ^map[engine.Local_ID]engine.Local_ID) -> []byte {
	context.allocator = context.temp_allocator
	before := undo.capture_json(ptr, tid)
	if before == nil do return nil
	ti := type_info_of(tid)
	copy_ptr, err := mem.alloc(ti.size, ti.align)
	if err != nil do return nil
	if !undo.write_json_value(copy_ptr, tid, before, {}, quiet = true) do return nil
	engine._remap_refs_in_value(copy_ptr, ti, moved)
	return undo.capture_json(copy_ptr, tid)
}

// The id a scene reference in the value at `ptr` names, when it is one: a
// Ref_Local, a Ref or a PPtr naming something of the scene (no guid).
@(private = "file")
_scene_ref_id :: proc(ptr: rawptr, tid: typeid) -> (id: engine.Local_ID, is_ref: bool) {
	switch tid {
	case typeid_of(engine.Ref_Local), typeid_of(engine.Owned):
		return (^engine.Ref_Local)(ptr).local_id, true
	case typeid_of(engine.Ref):
		r := (^engine.Ref)(ptr)
		return engine.pptr_guid_is_empty(r.pptr.guid) ? r.pptr.local_id : 0, true
	case typeid_of(engine.PPtr):
		r := (^engine.PPtr)(ptr)
		return engine.pptr_guid_is_empty(r.guid) ? r.local_id : 0, true
	}
	return 0, false
}

// Whether a reference naming `id` is one this walk looks for.
@(private = "file")
_wanted :: proc(id: engine.Local_ID, inside: ^map[engine.Local_ID]bool, into: bool) -> bool {
	return id != 0 && (id in inside) == into
}

// Appends the paths, as the inspector names them, of the fields of the value
// at `ptr` that hold a wanted reference: the reference itself, or the whole
// array or union holding it, which an override replaces as one.
@(private = "file")
_ref_fields :: proc(ptr: rawptr, ti: ^runtime.Type_Info, path: string, inside: ^map[engine.Local_ID]bool, into: bool, out: ^[dynamic]string) {
	if id, is_ref := _scene_ref_id(ptr, ti.id); is_ref {
		if _wanted(id, inside, into) do append(out, path)
		return
	}
	#partial switch info in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(info.field_count) {
			if tag, has := reflect.struct_tag_lookup(reflect.Struct_Tag(info.tags[i]), "json"); has && tag == "-" do continue
			name := info.names[i]
			sub := path == "" ? name : strings.concatenate({path, ".", name}, context.temp_allocator)
			_ref_fields(rawptr(uintptr(ptr) + info.offsets[i]), info.types[i], sub, inside, into, out)
		}
	case runtime.Type_Info_Array, runtime.Type_Info_Dynamic_Array, runtime.Type_Info_Slice, runtime.Type_Info_Union:
		if _holds_wanted(ptr, ti, inside, into) do append(out, path)
	}
}

// Whether the value at `ptr` holds a wanted reference anywhere.
@(private = "file")
_holds_wanted :: proc(ptr: rawptr, ti: ^runtime.Type_Info, inside: ^map[engine.Local_ID]bool, into: bool) -> bool {
	want := _Want{inside = inside, into = into}
	_each_ref(ptr, ti, proc(ref_ptr: rawptr, tid: typeid, user: rawptr) {
		w := (^_Want)(user)
		if id, _ := _scene_ref_id(ref_ptr, tid); _wanted(id, w.inside, w.into) do w.found = true
	}, &want)
	return want.found
}

@(private = "file")
_Want :: struct {
	inside: ^map[engine.Local_ID]bool,
	into:   bool,
	found:  bool,
}

// Empties every reference in the value at `ptr` that names an id out of
// `inside`.
@(private = "file")
_clear_refs_out :: proc(ptr: rawptr, ti: ^runtime.Type_Info, inside: ^map[engine.Local_ID]bool) {
	_each_ref(ptr, ti, proc(ref_ptr: rawptr, tid: typeid, user: rawptr) {
		inside := (^map[engine.Local_ID]bool)(user)
		id, _ := _scene_ref_id(ref_ptr, tid)
		if !_wanted(id, inside, false) do return
		switch tid {
		case typeid_of(engine.Ref_Local), typeid_of(engine.Owned): (^engine.Ref_Local)(ref_ptr)^ = {}
		case typeid_of(engine.Ref): (^engine.Ref)(ref_ptr)^ = {}
		case typeid_of(engine.PPtr): (^engine.PPtr)(ref_ptr)^ = {}
		}
	}, inside)
}

// Calls `visit` on every scene reference in the value at `ptr`: through
// structs (serialized fields only), arrays and the active union variant.
@(private = "file")
_each_ref :: proc(ptr: rawptr, ti: ^runtime.Type_Info, visit: proc(ref_ptr: rawptr, tid: typeid, user: rawptr), user: rawptr) {
	if ptr == nil || ti == nil do return
	if _, is_ref := _scene_ref_id(ptr, ti.id); is_ref {
		visit(ptr, ti.id, user)
		return
	}
	#partial switch info in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(info.field_count) {
			if tag, has := reflect.struct_tag_lookup(reflect.Struct_Tag(info.tags[i]), "json"); has && tag == "-" do continue
			_each_ref(rawptr(uintptr(ptr) + info.offsets[i]), info.types[i], visit, user)
		}
	case runtime.Type_Info_Array:
		for i in 0 ..< info.count do _each_ref(rawptr(uintptr(ptr) + uintptr(i * info.elem_size)), info.elem, visit, user)
	case runtime.Type_Info_Dynamic_Array:
		a := (^runtime.Raw_Dynamic_Array)(ptr)
		for i in 0 ..< a.len do _each_ref(rawptr(uintptr(a.data) + uintptr(i * info.elem_size)), info.elem, visit, user)
	case runtime.Type_Info_Slice:
		a := (^runtime.Raw_Slice)(ptr)
		for i in 0 ..< a.len do _each_ref(rawptr(uintptr(a.data) + uintptr(i * info.elem_size)), info.elem, visit, user)
	case runtime.Type_Info_Union:
		tag: i64
		tag_ptr := rawptr(uintptr(ptr) + info.tag_offset)
		switch info.tag_type.size {
		case 1: tag = i64((^u8)(tag_ptr)^)
		case 2: tag = i64((^u16)(tag_ptr)^)
		case 4: tag = i64((^u32)(tag_ptr)^)
		case 8: tag = i64((^u64)(tag_ptr)^)
		}
		idx := info.no_nil ? tag : tag - 1
		if idx >= 0 && int(idx) < len(info.variants) do _each_ref(ptr, info.variants[idx], visit, user)
	}
}
