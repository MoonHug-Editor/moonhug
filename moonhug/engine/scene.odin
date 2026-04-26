package engine

import "core:encoding/json"

Scene :: struct {
	generation:    int,
	next_local_id: Local_ID,
	root:          Ref,
	path:          string,
	nested_scenes: [dynamic]NestedScene,
}

scene_new :: proc() -> ^Scene {
	s := new(Scene)
	s.generation = 1 // FIX
	return s
}

scene_destroy :: proc(s: ^Scene) {
	if s == nil do return
	if s.root.handle != {} {
		transform_destroy(Transform_Handle(s.root.handle))
	}
	delete(s.path)
	for &ns in s.nested_scenes {
		for &ov in ns.overrides {
			delete(ov.property_path)
			json.destroy_value(ov.value)
		}
		delete(ns.overrides)
	}
	delete(s.nested_scenes)
	s.generation = 0
	free(s)
}

scene_next_id :: proc(s: ^Scene) -> Local_ID {
	s.next_local_id += 1
	id := s.next_local_id
	return id
}

scene_set_root :: proc(s: ^Scene, tH: Transform_Handle) {
	if s == nil do return
	w := ctx_world()
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil do return
	if pool_valid(&w.transforms, t.parent.handle) {
		transform_unlink_from_parent(tH)
	}
	t.parent = {}
	s.root = Ref{ pptr = PPtr{local_id = t.local_id}, handle = Handle(tH) }
}

scene_ensure_root :: proc(s: ^Scene) {
	if s == nil do return
	w := ctx_world()
	if pool_valid(&w.transforms, s.root.handle) do return
	tH := transform_new("Root")
	scene_set_root(s, tH)
}

scene_clear_root :: proc(s: ^Scene) {
	if s == nil do return
	s.root = {}
}
