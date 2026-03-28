package engine

import "core:encoding/json"
import "core:os"
import "core:fmt"
import "core:strings"

scene_files : map[Asset_GUID]SceneFile


_collect_transform_tree :: proc(w: ^World, tH: Transform_Handle, sf: ^SceneFile) {
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil do return

	t_copy := t^
	t_copy.children = make([dynamic]Ref, len(t.children))
	copy(t_copy.children[:], t.children[:])
	t_copy.components = make([dynamic]Owned, len(t.components))
	copy(t_copy.components[:], t.components[:])
	append(&sf.transforms, t_copy)

	for &c in t.components {
		if c.handle.type_key == INVALID_TYPE_KEY do continue
		world_pool_collect(w, c.handle, sf)
	}

	for child in t.children {
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

scene_load_path :: proc(path: string) -> ^Scene {
	sf, ok := scene_file_load(path)
	if !ok do return nil
	defer scene_file_destroy(&sf)

	s := scene_load_single(&sf)
	if s != nil {
		s.path = strings.clone(path)
	}
	return s
}

scene_load_additive_path :: proc(path: string) -> ^Scene {
	sf, ok := scene_file_load(path)
	if !ok do return nil
	defer scene_file_destroy(&sf)

	s := scene_load_additive(&sf)
	if s != nil {
		s.path = strings.clone(path)
	}
	return s
}

