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

// Returns the local_id for `h` in `s.local_ids`. For handles already in the
// bimap, returns the existing lid. For nested-owned handles (transforms or
// components inside a resolved prefab), creates a Breadcrumb anchored at the
// outermost native NS — resolution at load walks the runtime NS tree by
// (source_prefab guid) to find the leaf NS host, then locates the target by
// prefab-namespaced lid. Otherwise mints a raw bimap entry.
sm_local_id_get_or_mint :: proc(s: ^Scene, h: Handle) -> Local_ID {
	if s == nil do return 0
	if lid, ok := s.local_ids.backward[h]; ok do return lid

	if bc_lid, ok := _try_create_breadcrumb_for_handle(s, h); ok {
		return bc_lid
	}

	// Live, non-nested entity not yet registered in the bimap. Use its own
	// local_id (assigned at creation time) and register it now so subsequent
	// lookups dedupe and so save+reload round-trips correctly.
	w := ctx_world()
	existing_lid: Local_ID
	if h.type_key == .Transform {
		t := pool_get(&w.transforms, h)
		if t != nil do existing_lid = t.local_id
	} else {
		raw := world_pool_get(w, h)
		if raw != nil {
			base := cast(^CompData)raw
			existing_lid = base.local_id
		}
	}
	if existing_lid != 0 {
		bimap_insert(&s.local_ids, existing_lid, h)
		return existing_lid
	}

	new_lid := scene_next_id(s)
	bimap_insert(&s.local_ids, new_lid, h)
	return new_lid
}

@(private)
_try_create_breadcrumb_for_handle :: proc(s: ^Scene, h: Handle) -> (Local_ID, bool) {
	if s == nil do return 0, false
	w := ctx_world()

	owner_tH: Transform_Handle
	target_lid: Local_ID

	if h.type_key == .Transform {
		t := pool_get(&w.transforms, h)
		if t == nil || !t.nested_owned do return 0, false
		owner_tH = Transform_Handle(h)
		target_lid = t.local_id
	} else {
		raw := world_pool_get(w, h)
		if raw == nil do return 0, false
		base := cast(^CompData)raw
		if !base.nested_owned do return 0, false
		owner_tH = base.owner
		target_lid = base.local_id
	}

	// Find the immediate NS that wraps the target.
	host_tH := transform_immediate_nested_host(owner_tH)
	if host_tH == {} do return 0, false
	host_t := pool_get(&w.transforms, Handle(host_tH))
	if host_t == nil do return 0, false
	leaf_ns := scene_find_nested_scene_for_host(host_t.scene, host_tH)
	if leaf_ns == nil do return 0, false

	// Anchor breadcrumb at the outermost native NS in the chain. Resolution
	// walks the runtime NS tree from native down, un-projecting through each
	// inner NS's local_id_in_parent.
	native_ns: ^NestedScene = leaf_ns
	projected := target_lid
	if leaf_ns.expand_parent != {} {
		lid_chain, nat_ns, chok := _inner_chain_lids_to_native_public(s, leaf_ns)
		if !chok || nat_ns == nil do return 0, false
		native_ns = nat_ns
		// Forward-project through the chain top-down so resolve un-projects in
		// the same order.
		for i := len(lid_chain) - 1; i >= 0; i -= 1 {
			projected = local_id_project(lid_chain[i], projected)
		}
	}

	src := PPtr{guid = leaf_ns.source_prefab, local_id = projected}
	bc_lid, ok := breadcrumb_create(s, native_ns.local_id, src)
	if !ok do return 0, false

	// Re-point bimap entry from synthetic placeholder to the real handle so
	// in-session reverse lookups dedupe on the real handle. On reload the
	// breadcrumb resolution pass repopulates with the freshly resolved handle.
	bimap_remove_by_key(&s.local_ids, bc_lid)
	bimap_insert(&s.local_ids, bc_lid, h)
	return bc_lid, true
}
