package engine

Found_Object :: struct {
	handle: Handle,
	name: string,
}

// Editor-facing equivalent of FindObjectsOfType, scoped to currently loaded scenes.
// If `root_scene` is non-nil, only objects belonging to that root scene are returned.
// For .Transform, walks the transform tree; for component type_keys, walks every
// Transform and collects matches from t.components using the owning Transform name.
sm_find_objects_of_type :: proc(key: TypeKey, root_scene: ^Scene = nil, allocator := context.temp_allocator) -> []Found_Object {
	results: [dynamic]Found_Object
	results.allocator = allocator
	if key == INVALID_TYPE_KEY do return results[:]

	sm := ctx_scene_manager()
	if sm == nil do return results[:]

	target_root: ^Scene
	if root_scene != nil do target_root = root_scene

	for i in 0 ..< sm.count {
		s := sm.loaded[i]
		if !sm_scene_is_valid(s) do continue
		if target_root != nil && s != target_root do continue
		if !pool_valid(&ctx_world().transforms, s.root.handle) do continue
		_collect_from_subtree(Transform_Handle(s.root.handle), key, &results)
	}
	return results[:]
}

// Returns the topmost (root) Scene the Transform belongs to: walks up parents
// in the transform pool until parent is invalid, then returns that node's .scene.
// For nested-owned transforms whose .scene points at a nested Scene, this still
// resolves to the outermost loaded Scene.
sm_get_root_scene_of_transform :: proc(tH: Transform_Handle) -> ^Scene {
	w := ctx_world()
	cur := tH
	for {
		t := pool_get(&w.transforms, Handle(cur))
		if t == nil do return nil
		if !pool_valid(&w.transforms, t.parent.handle) do return t.scene
		cur = Transform_Handle(t.parent.handle)
	}
}

@(private)
_collect_from_subtree :: proc(tH: Transform_Handle, key: TypeKey, out: ^[dynamic]Found_Object) {
	w := ctx_world()
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil do return

	if key == .Transform {
		append(out, Found_Object{handle = Handle(tH), name = t.name})
	} else {
		for c in t.components {
			if c.handle.type_key != key do continue
			append(out, Found_Object{handle = c.handle, name = t.name})
		}
	}

	for child in t.children {
		_collect_from_subtree(Transform_Handle(child.handle), key, out)
	}
}

// Returns the local_id for `h` in `s.local_ids`, minting a new entry if absent.
// Save-time will turn freshly-minted entries into breadcrumbs for objects that
// don't have a stable local_id in this root scene yet (e.g. nested-owned).
sm_local_id_get_or_mint :: proc(s: ^Scene, h: Handle) -> Local_ID {
	if s == nil do return 0
	if lid, ok := s.local_ids.backward[h]; ok do return lid
	new_lid := scene_next_id(s)
	bimap_insert(&s.local_ids, new_lid, h)
	return new_lid
}
