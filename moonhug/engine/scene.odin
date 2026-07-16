package engine

import "core:encoding/json"

Scene :: struct {
	generation:           int,
	next_local_id:        Local_ID,
	root:                 Ref,
	path:                 string,
	asset_guid:           Asset_GUID `json:"-"`,
	local_ids:            Bimap(Local_ID, Handle) `json:"-"`,
	breadcrumb_data:      map[Local_ID]Breadcrumb,
	breadcrumb_synth_seq: u32,
	nested_scenes:        [dynamic]NestedScene,
}

scene_new :: proc() -> ^Scene {
	s := new(Scene)
	s.generation = 1 // FIX
	s.next_local_id = 1
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
		delete(ns.source_of_inst)
	}
	delete(s.nested_scenes)
	cleanup_Bimap(&s.local_ids)
	delete(s.breadcrumb_data)
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

@(private)
_scene_find_transform_local_id :: proc(s: ^Scene, id: Local_ID, include_nested: bool) -> (Transform_Handle, bool) {
	if s == nil || id == 0 do return {}, false
	if breadcrumb_is_placeholder(s, id) do return {}, false
	w := ctx_world()
	for i in 0 ..< len(w.transforms.slots) {
		slot := &w.transforms.slots[i]
		if !slot.alive do continue
		tr := &slot.data
		if tr.scene != s do continue
		if tr.nested_owned {
			// Composed contents carry deterministic host-namespace lids
			// (docs/NestedPrefabs.md), so matching them can't collide with
			// outer lids. Their scene_asset_guid is the SOURCE scene's — the
			// mismatch filter below only applies to outer transforms.
			if !include_nested do continue
		} else if !asset_guid_is_empty(s.asset_guid) && !asset_guid_is_empty(tr.scene_asset_guid) && tr.scene_asset_guid != s.asset_guid {
			continue
		}
		if tr.local_id == id {
			return Transform_Handle(Handle{index = u32(i), generation = slot.generation, type_key = .Transform}), true
		}
	}
	return {}, false
}

// Undo-grade lookup: outer transforms only — structural/value undo must never
// target nested-scene contents.
scene_find_outer_transform_local_id :: proc(s: ^Scene, id: Local_ID) -> (Transform_Handle, bool) {
	return _scene_find_transform_local_id(s, id, include_nested = false)
}

// Selection-grade lookup: also matches nested-scene contents. Use it to FIND
// an object (selection restore, reveal, display) — never to mutate it.
scene_find_selectable_transform_local_id :: proc(s: ^Scene, id: Local_ID) -> (Transform_Handle, bool) {
	return _scene_find_transform_local_id(s, id, include_nested = true)
}

scene_ref_resolve_transform :: proc(s: ^Scene, r: Ref, parent_for_local_id: Transform_Handle = {}) -> (Transform_Handle, bool) {
	if s == nil do return {}, false
	w := ctx_world()
	parent_h := Handle(parent_for_local_id)
	use_parent := parent_for_local_id != Transform_Handle{}

	if pool_valid(&w.transforms, r.handle) {
		t := pool_get(&w.transforms, r.handle)
		if t != nil && t.scene == s {
			if use_parent {
				if t.parent.handle == parent_h {
					return Transform_Handle(r.handle), true
				}
			} else {
				return Transform_Handle(r.handle), true
			}
		}
	}
	if r.pptr.local_id == 0 do return {}, false
	if !pptr_guid_is_empty(r.pptr.guid) do return {}, false
	if breadcrumb_is_placeholder(s, r.pptr.local_id) do return {}, false
	count := 0
	last: Transform_Handle
	for i in 0 ..< len(w.transforms.slots) {
		slot := &w.transforms.slots[i]
		if !slot.alive do continue
		tr := &slot.data
		if tr.scene != s || tr.local_id != r.pptr.local_id do continue
		if use_parent && tr.parent.handle != parent_h do continue
		count += 1
		if count > 1 {
			return {}, false
		}
		last = Transform_Handle(Handle{index = u32(i), generation = slot.generation, type_key = .Transform})
	}
	if count == 1 {
		return last, true
	}
	return {}, false
}

scene_hierarchy_transform_is_nested_scene_host :: proc(s: ^Scene, tH: Transform_Handle) -> bool {
	if s == nil do return false
	w := ctx_world()
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil || t.scene != s do return false
	if !t.nested_owned {
		if h, ok := bimap_get(&s.local_ids, t.local_id); ok {
			if h != Handle(tH) do return false
		}
		if !asset_guid_is_empty(s.asset_guid) && !asset_guid_is_empty(t.scene_asset_guid) && t.scene_asset_guid != s.asset_guid {
			return false
		}
	}
	return scene_find_nested_scene_for_host(s, tH) != nil
}
