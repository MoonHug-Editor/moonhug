package engine

import "core:encoding/json"
import "core:os"
import "core:fmt"
import "core:strings"
import "base:runtime"

_remap_refs_in_value :: proc(ptr: rawptr, ti: ^runtime.Type_Info, remap: ^map[Local_ID]Local_ID) {
	if ptr == nil || ti == nil do return
	base := runtime.type_info_base(ti)
	if base == nil do return

	#partial switch info in base.variant {
	case runtime.Type_Info_Struct:
		tid := ti.id
		if tid == typeid_of(PPtr) {
			pptr := cast(^PPtr)ptr
			if pptr.local_id != 0 {
				if new_id, ok := remap[pptr.local_id]; ok {
					pptr.local_id = new_id
				}
			}
			return
		}
		if tid == typeid_of(Ref) {
			ref := cast(^Ref)ptr
			if ref.pptr.local_id != 0 {
				if new_id, ok := remap[ref.pptr.local_id]; ok {
					ref.pptr.local_id = new_id
				}
			}
			return
		}
		if tid == typeid_of(Ref_Local) || tid == typeid_of(Owned) {
			rl := cast(^Ref_Local)ptr
			if rl.local_id != 0 {
				if new_id, ok := remap[rl.local_id]; ok {
					rl.local_id = new_id
				}
			}
			return
		}

		count := int(info.field_count)
		for i in 0..<count {
			field_ptr := rawptr(uintptr(ptr) + info.offsets[i])
			_remap_refs_in_value(field_ptr, info.types[i], remap)
		}

	case runtime.Type_Info_Union:
		tag_ptr := rawptr(uintptr(ptr) + info.tag_offset)
		tag: i64
		switch info.tag_type.size {
		case 1: tag = i64((cast(^u8)tag_ptr)^)
		case 2: tag = i64((cast(^u16)tag_ptr)^)
		case 4: tag = i64((cast(^u32)tag_ptr)^)
		case 8: tag = i64((cast(^u64)tag_ptr)^)
		}
		idx := tag if info.no_nil else tag - 1
		if idx < 0 || int(idx) >= len(info.variants) do return
		variant_ti := info.variants[idx]
		_remap_refs_in_value(ptr, variant_ti, remap)

	case runtime.Type_Info_Dynamic_Array:
		dyn := cast(^runtime.Raw_Dynamic_Array)ptr
		if dyn.data == nil || dyn.len == 0 do return
		elem_size := info.elem_size
		for i in 0..<dyn.len {
			elem_ptr := rawptr(uintptr(dyn.data) + uintptr(i * elem_size))
			_remap_refs_in_value(elem_ptr, info.elem, remap)
		}

	case runtime.Type_Info_Array:
		elem_size := info.elem_size
		for i in 0..<info.count {
			elem_ptr := rawptr(uintptr(ptr) + uintptr(i * elem_size))
			_remap_refs_in_value(elem_ptr, info.elem, remap)
		}
	}
}

_collect_transform_tree :: proc(w: ^World, tH: Transform_Handle, sf: ^SceneFile) {
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil do return
	if t.nested_owned do return

	t_copy := t^
	t_copy.name = strings.clone(t.name)
	t_copy.children = make([dynamic]Ref, 0, len(t.children))
	for child in t.children {
		ct := pool_get(&w.transforms, child.handle)
		if ct != nil && ct.nested_owned do continue
		append(&t_copy.children, child)
	}
	t_copy.components = make([dynamic]Owned, len(t.components))
	copy(t_copy.components[:], t.components[:])
	append(&sf.transforms, t_copy)

	for &c in t.components {
		if c.handle.type_key == INVALID_TYPE_KEY do continue
		world_pool_collect(w, c.handle, sf)
	}

	for child in t.children {
		ct := pool_get(&w.transforms, child.handle)
		if ct != nil && ct.nested_owned do continue
		_collect_transform_tree(w, Transform_Handle(child.handle), sf)
	}
}

scene_save :: proc(s: ^Scene, path: string) -> bool {
	if s == nil do return false
	w := ctx_world()

	sf := SceneFile{}
	sf.next_local_id = s.next_local_id

	if s.root.handle != {} {
		t := pool_get(&w.transforms, s.root.handle)
		if t != nil {
			sf.root = t.local_id
			_collect_transform_tree(w, Transform_Handle(s.root.handle), &sf)
		}
	}

	opts := json.Marshal_Options{
		spec       = .JSON,
		pretty     = true,
		use_spaces = true,
		spaces     = 2,
	}
	data, err := json.marshal(sf, opts)
	if err != nil {
		fmt.printf("[Scene] Failed to marshal scene: %v\n", err)
		scene_file_destroy(&sf)
		return false
	}
	defer delete(data)

	scene_file_destroy(&sf)

	if write_err := os.write_entire_file(path, data); write_err != nil {
		fmt.printf("[Scene] Failed to write file: %s\n", path)
		return false
	}

	delete(s.path)
	s.path = strings.clone(path)

	fmt.printf("[Scene] Saved scene to %s\n", path)
	return true
}

scene_file_load :: proc(filepath: string) -> (SceneFile, bool) {
	data, read_ok := os.read_entire_file(filepath, context.allocator)
	if read_ok != nil {
		fmt.printf("[Scene] Failed to read file: %s\n", filepath)
		return {}, false
	}
	defer delete(data)

	sf: SceneFile
	unmarshal_err := json.unmarshal(data, &sf)
	if unmarshal_err != nil {
		fmt.printf("[Scene] Failed to unmarshal scene: %v\n", unmarshal_err)
		return {}, false
	}

	return sf, true
}

resolve_handle :: proc(local_id: Local_ID, id_map: map[Local_ID]Handle) -> (Handle, bool) {
	if local_id == 0 do return {}, false
	if h, ok := id_map[local_id]; ok {
		return h, true
	}
	return {}, false
}

scene_load_single_path :: proc(path: string) -> ^Scene {
	sf, ok := scene_file_load(path)
	if !ok do return nil
	defer scene_file_destroy(&sf)

	s := _scene_load_single(&sf)
	if s != nil {
		s.path = strings.clone(path)
	}
	return s
}

scene_load_additive_path :: proc(path: string) -> ^Scene {
	sf, ok := scene_file_load(path)
	if !ok do return nil
	defer scene_file_destroy(&sf)

	s := _scene_load_additive(&sf)
	if s != nil {
		s.path = strings.clone(path)
	}
	return s
}

scene_copy_subtree :: proc(tH: Transform_Handle) -> []byte {
	w := ctx_world()
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil do return nil

	sf := SceneFile{}
	sf.root = t.local_id
	_collect_transform_tree(w, tH, &sf)
	defer scene_file_destroy(&sf)

	opts := json.Marshal_Options{spec = .JSON, pretty = false}
	data, err := json.marshal(sf, opts)
	if err != nil {
		fmt.printf("[Scene] Failed to marshal subtree: %v\n", err)
		delete(data)
		return nil
	}
	return data
}

scene_paste_subtree :: proc(data: []byte, parent: Transform_Handle) -> Transform_Handle {
	if parent == {} || len(data) == 0 do return {}
	w := ctx_world()
	if !pool_valid(&w.transforms, Handle(parent)) do return {}

	sf: SceneFile
	if err := json.unmarshal(data, &sf); err != nil {
		fmt.printf("[Scene] Failed to unmarshal subtree: %v\n", err)
		return {}
	}
	defer scene_file_destroy(&sf)

	pt := pool_get(&w.transforms, Handle(parent))
	s := pt.scene

	_scene_file_remap_local_ids(&sf, s)
	root_tH := _scene_load_as_child(&sf, parent, s)
	if root_tH != {} && !ctx_get().is_playmode {
		_scene_resolve_nested_in_subtree(root_tH)
	}
	return root_tH
}

scene_duplicate_subtree :: proc(tH: Transform_Handle) -> Transform_Handle {
	w := ctx_world()
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil do return {}

	parent := Transform_Handle(t.parent.handle)
	if !pool_valid(&w.transforms, Handle(parent)) do return {}

	data := scene_copy_subtree(tH)
	defer delete(data)

	return scene_paste_subtree(data, parent)
}
