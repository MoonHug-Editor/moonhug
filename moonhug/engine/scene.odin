package engine

Scene :: struct {
	generation:    int,
	next_local_id: Local_ID,
	root:          Ref,
	path:          string,
}

make_pScene :: proc() -> any {
	s := scene_new()
	return s^
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
	s.generation = 0
	free(s)
}

scene_get_active :: proc() -> ^Scene {
	return sm_get_active_scene()
}

scene_set_active :: proc(s: ^Scene) {
	sm_set_active_scene(s)
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
