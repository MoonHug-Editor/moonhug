package engine

import "core:encoding/json"

// A component record whose "__type" guid has no registered component in this
// binary (its package isn't compiled in). Preserved VERBATIM across load/save
// — Unity's missing-script behavior; a binary
// with the package installed reads the record back intact.
Unknown_Component :: struct {
	owner_lid: Local_ID,   // serialized transform that carried the record
	local_id:  Local_ID,   // the record's own base.local_id
	value:     json.Value, // cloned record, re-emitted on save
}

Scene :: struct {
	generation:           int,
	next_local_id:        Local_ID,
	// The counter as loaded from (or last written to) the file. Serialization
	// seeds from THIS, not next_local_id: the live counter also covers
	// transient allocations that are never persisted (root-variant host pegs),
	// so persisting it would make the saved value drift with load history.
	file_next_local_id:   Local_ID `json:"-"`,
	root:                 Ref,
	path:                 string,
	asset_guid:           Asset_GUID `json:"-"`,
	local_ids:            Bimap(Local_ID, Handle) `json:"-"`,
	breadcrumb_data:      map[Local_ID]Breadcrumb,
	breadcrumb_synth_seq: u32,
	nested_scenes:        [dynamic]NestedScene,
	unknown_components:   [dynamic]Unknown_Component `json:"-"`,
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
	for &uc in s.unknown_components {
		json.destroy_value(uc.value)
	}
	delete(s.unknown_components)
	cleanup_Bimap(&s.local_ids)
	delete(s.breadcrumb_data)
	s.generation = 0
	free(s)
}

// The editor's missing-component row removes through this: detaches the
// preserved record AND the owning transform's dangling components entry (its
// handle never resolves — the package isn't compiled in). Returns the entry's
// list index for undo, or ok=false when no record matched.
transform_remove_unknown_comp :: proc(tH: Transform_Handle, comp_local_id: Local_ID) -> (list_index: int, ok: bool) {
	w := ctx_world()
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil || t.scene == nil do return -1, false
	s := t.scene
	found := false
	for &uc, i in s.unknown_components {
		if uc.owner_lid != t.local_id || uc.local_id != comp_local_id do continue
		json.destroy_value(uc.value)
		ordered_remove(&s.unknown_components, i)
		found = true
		break
	}
	if !found do return -1, false
	list_index = -1
	for i in 0 ..< len(t.components) {
		if t.components[i].local_id == comp_local_id {
			list_index = i
			ordered_remove(&t.components, i)
			break
		}
	}
	return list_index, true
}

// Undo of transform_remove_unknown_comp: re-stashes the record (cloning
// `value` — caller keeps ownership) and re-inserts the components entry at
// its old list index (append when out of range).
transform_restore_unknown_comp :: proc(tH: Transform_Handle, comp_local_id: Local_ID, value: json.Value, list_index: int) {
	w := ctx_world()
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil || t.scene == nil do return
	append(&t.scene.unknown_components, Unknown_Component{
		owner_lid = t.local_id,
		local_id  = comp_local_id,
		value     = json.clone_value(value),
	})
	idx := list_index
	if idx < 0 || idx > len(t.components) do idx = len(t.components)
	inject_at(&t.components, idx, Owned{local_id = comp_local_id})
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
