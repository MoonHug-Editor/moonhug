package engine

import "core:encoding/json"
import "core:os"
import "core:fmt"
import "core:strings"
import "base:runtime"

// Walks `ptr` of type `ti` and, for every PPtr / Ref / Ref_Local / Owned found,
// resolves its `handle` from `local_id`.
//
// `file_local` is the id->handle table of the SceneFile the value was loaded
// from, when resolving happens at load time. Intra-file references MUST resolve
// against it, not the scene bimap: a nested prefab keeps its own local_id
// namespace (Unity resolves intra-prefab fileIDs the same way), and its ids are
// never registered in the host scene's bimap — a bimap lookup would either miss
// or, worse, silently bind to an unrelated host object with the same id. The
// bimap is the fallback for ids not present in the file (breadcrumb pegs).
// PPtr entries with a non-empty guid (cross-asset) are skipped — those are
// resolved separately at asset-resolve time.
_resolve_lid :: proc(s: ^Scene, file_local: ^map[Local_ID]Handle, lid: Local_ID) -> (Handle, bool) {
	if file_local != nil {
		if h, ok := file_local^[lid]; ok do return h, true
	}
	return bimap_get(&s.local_ids, lid)
}

// `only_unbound` restricts resolution to refs whose handle is not currently a
// live pool handle (zero, dead, or a synthetic breadcrumb placeholder). This is
// how the post-migration sweep stays namespace-safe: a ref that already holds a
// real handle was bound in its own file's namespace and must not be rebound via
// the host bimap (same-numbered lids across namespaces would mis-bind); a ref
// holding a placeholder is by definition breadcrumb-mediated and needs the
// migrated binding — regardless of which component owns it or how deep it sits.
_resolve_refs_in_value :: proc(ptr: rawptr, ti: ^runtime.Type_Info, s: ^Scene, file_local: ^map[Local_ID]Handle = nil, only_unbound := false) {
	if ptr == nil || ti == nil || s == nil do return
	base := runtime.type_info_base(ti)
	if base == nil do return

	#partial switch info in base.variant {
	case runtime.Type_Info_Struct:
		tid := ti.id
		if tid == typeid_of(PPtr) {
			pptr := cast(^PPtr)ptr
			// PPtr has no handle field; nothing to resolve here.
			_ = pptr
			return
		}
		if tid == typeid_of(Ref) {
			ref := cast(^Ref)ptr
			if ref.pptr.local_id != 0 && pptr_guid_is_empty(ref.pptr.guid) {
				if only_unbound && world_pool_valid(ctx_world(), ref.handle) do return
				if h, ok := _resolve_lid(s, file_local, ref.pptr.local_id); ok {
					ref.handle = h
				}
			}
			return
		}
		if tid == typeid_of(Ref_Local) || tid == typeid_of(Owned) {
			rl := cast(^Ref_Local)ptr
			if rl.local_id != 0 {
				if only_unbound && world_pool_valid(ctx_world(), rl.handle) do return
				if h, ok := _resolve_lid(s, file_local, rl.local_id); ok {
					rl.handle = h
				}
			}
			return
		}

		count := int(info.field_count)
		for i in 0..<count {
			field_ptr := rawptr(uintptr(ptr) + info.offsets[i])
			_resolve_refs_in_value(field_ptr, info.types[i], s, file_local, only_unbound)
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
		_resolve_refs_in_value(ptr, variant_ti, s, file_local, only_unbound)

	case runtime.Type_Info_Dynamic_Array:
		dyn := cast(^runtime.Raw_Dynamic_Array)ptr
		if dyn.data == nil || dyn.len == 0 do return
		elem_size := info.elem_size
		for i in 0..<dyn.len {
			elem_ptr := rawptr(uintptr(dyn.data) + uintptr(i * elem_size))
			_resolve_refs_in_value(elem_ptr, info.elem, s, file_local, only_unbound)
		}

	case runtime.Type_Info_Array:
		elem_size := info.elem_size
		for i in 0..<info.count {
			elem_ptr := rawptr(uintptr(ptr) + uintptr(i * elem_size))
			_resolve_refs_in_value(elem_ptr, info.elem, s, file_local, only_unbound)
		}
	}
}

// Walks `ptr` and rewrites every Ref/Ref_Local/Owned whose resolved handle is
// `old_h` to `new_h`. Used when nested-scene absorption destroys the prefab's
// root transform and the host transform takes its place — refs bound to the
// prefab root must follow.
_rewrite_handle_refs_in_value :: proc(ptr: rawptr, ti: ^runtime.Type_Info, old_h: Handle, new_h: Handle) {
	if ptr == nil || ti == nil do return
	base := runtime.type_info_base(ti)
	if base == nil do return

	#partial switch info in base.variant {
	case runtime.Type_Info_Struct:
		tid := ti.id
		if tid == typeid_of(PPtr) {
			return
		}
		if tid == typeid_of(Ref) {
			ref := cast(^Ref)ptr
			if ref.handle == old_h do ref.handle = new_h
			return
		}
		if tid == typeid_of(Ref_Local) || tid == typeid_of(Owned) {
			rl := cast(^Ref_Local)ptr
			if rl.handle == old_h do rl.handle = new_h
			return
		}

		count := int(info.field_count)
		for i in 0..<count {
			field_ptr := rawptr(uintptr(ptr) + info.offsets[i])
			_rewrite_handle_refs_in_value(field_ptr, info.types[i], old_h, new_h)
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
		_rewrite_handle_refs_in_value(ptr, variant_ti, old_h, new_h)

	case runtime.Type_Info_Dynamic_Array:
		dyn := cast(^runtime.Raw_Dynamic_Array)ptr
		if dyn.data == nil || dyn.len == 0 do return
		elem_size := info.elem_size
		for i in 0..<dyn.len {
			elem_ptr := rawptr(uintptr(dyn.data) + uintptr(i * elem_size))
			_rewrite_handle_refs_in_value(elem_ptr, info.elem, old_h, new_h)
		}

	case runtime.Type_Info_Array:
		elem_size := info.elem_size
		for i in 0..<info.count {
			elem_ptr := rawptr(uintptr(ptr) + uintptr(i * elem_size))
			_rewrite_handle_refs_in_value(elem_ptr, info.elem, old_h, new_h)
		}
	}
}

// New lid for a record during a SceneFile remap: the mapper decides (projection
// into / out of an instance namespace), or the scene counter mints one (paste).
_remap_new_id :: proc(s: ^Scene, mapper: proc(user: rawptr, old: Local_ID) -> Local_ID, user: rawptr, old: Local_ID) -> Local_ID {
	if mapper != nil do return mapper(user, old)
	return scene_next_id(s)
}

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
	t_copy.components = make([dynamic]Owned, 0, len(t.components))
	for c in t.components {
		if c.handle.type_key == INVALID_TYPE_KEY do continue
		raw := world_pool_get(w, c.handle)
		if raw != nil {
			base := cast(^CompData)raw
			if base.nested_owned do continue
		}
		append(&t_copy.components, c)
	}
	append(&sf.transforms, t_copy)

	for &c in t.components {
		if c.handle.type_key == INVALID_TYPE_KEY do continue
		raw := world_pool_get(w, c.handle)
		if raw != nil {
			base := cast(^CompData)raw
			if base.nested_owned do continue
		}
		world_pool_collect(w, c.handle, sf)
	}

	for child in t.children {
		ct := pool_get(&w.transforms, child.handle)
		if ct != nil && ct.nested_owned do continue
		_collect_transform_tree(w, Transform_Handle(child.handle), sf)
	}
}

// Walks a variant's resolved root subtree and collects only the variant's OWN
// added content — non-nested-owned transforms grafted under the (nested-owned)
// base content. Each such transform's serialized parent lid is rewritten to its
// nearest nested-owned ancestor's lid (the base namespace lid), so that on
// reload the addition grafts back under the materialized base.
// `root_subst` remaps the synthesized placeholder root's runtime lid to the
// base root SOURCE lid that is written as sf.root, so additions parented at the
// placeholder serialize with a parent lid that reload can graft against.
_collect_variant_added_subtree :: proc(w: ^World, tH: Transform_Handle, sf: ^SceneFile, root_tH: Transform_Handle, root_subst: Local_ID) {
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil do return
	// The parent lid additions should serialize with: the base-namespace source
	// lid for the placeholder root, else the ancestor's own (base-namespace) lid.
	parent_lid := tH == root_tH ? root_subst : t.local_id
	for child in t.children {
		ct := pool_get(&w.transforms, child.handle)
		if ct == nil do continue
		if ct.nested_owned {
			// Stay within the base subtree looking for added (non-owned) content.
			_collect_variant_added_subtree(w, Transform_Handle(child.handle), sf, root_tH, root_subst)
			continue
		}
		// Non-nested-owned child of a nested-owned ancestor → variant addition.
		// Collect its (non-owned) subtree, then pin its parent lid to the base
		// ancestor so the graft is reconstructable on load.
		before := len(sf.transforms)
		_collect_transform_tree(w, Transform_Handle(child.handle), sf)
		for i in before..<len(sf.transforms) {
			if sf.transforms[i].local_id == ct.local_id {
				sf.transforms[i].parent = Ref{ pptr = PPtr{local_id = parent_lid} }
				break
			}
		}
	}
}

// Walks the nested-owned subtree for override capture. `outer_ns` is the
// NestedScene we're capturing for; `outer_host` is the live transform it
// resolves to. Items belonging to a *different* NS (inner prefabs nested under
// this one) live in their own namespace and would collide with the outer
// prefab's local_ids during diff (see Unity's PrefabInstance/m_Modifications
// model — overrides only address items in the immediate prefab). When we hit
// such a boundary we still serialize the host transform itself (it is the
// outer prefab's content), but stop pulling in its components and children.
_collect_nested_owned_subtree :: proc(
	w: ^World,
	tH: Transform_Handle,
	sf: ^SceneFile,
	root_local_id_override: Local_ID = 0,
	outer_ns: ^NestedScene = nil,
	outer_host: Transform_Handle = {},
) {
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil do return

	is_inner_boundary := false
	if outer_ns != nil && tH != outer_host {
		owning := scene_find_nested_scene_for_host(t.scene, tH)
		if owning != nil && owning != outer_ns do is_inner_boundary = true
	}

	t_copy := t^
	if root_local_id_override != 0 do t_copy.local_id = root_local_id_override
	t_copy.name = strings.clone(t.name)
	t_copy.children = make([dynamic]Ref, 0, len(t.children))
	if !is_inner_boundary {
		for child in t.children {
			ct := pool_get(&w.transforms, child.handle)
			if ct != nil do append(&t_copy.children, child)
		}
	}
	t_copy.components = make([dynamic]Owned, 0, len(t.components))
	if !is_inner_boundary {
		for c in t.components {
			if c.handle.type_key == INVALID_TYPE_KEY do continue
			raw := world_pool_get(w, c.handle)
			if raw != nil {
				base := cast(^CompData)raw
				if base.nested_owned do append(&t_copy.components, c)
			}
		}
	}
	append(&sf.transforms, t_copy)

	if is_inner_boundary do return

	for &c in t.components {
		if c.handle.type_key == INVALID_TYPE_KEY do continue
		raw := world_pool_get(w, c.handle)
		if raw == nil do continue
		base := cast(^CompData)raw
		if base.nested_owned do world_pool_collect(w, c.handle, sf)
	}

	for child in t.children {
		ct := pool_get(&w.transforms, child.handle)
		if ct != nil && ct.nested_owned {
			_collect_nested_owned_subtree(w, Transform_Handle(child.handle), sf, 0, outer_ns, outer_host)
		}
	}
}

// Computes the prefab-chain baked base for `ns`: starting from `ns.source_prefab`'s
// raw, applies each prefab in the chain's NS-for-this-child overrides in order
// (outermost-first), producing the bytes that represent "what `ns` looks like
// before any root-scene overrides are applied." Caller owns the returned bytes
// when ok is true.
//
// For native NS (expand_parent == {}) this is just the prefab raw — no chain.
// For depth-N inner NS, walks N levels of outer prefab files.
// Package-visible wrapper so nested_scene_revert_override can reuse this exact
// baseline (capture and revert then agree on what "before overrides" means).
chain_baked_base_for_ns :: proc(s: ^Scene, ns: ^NestedScene) -> ([]byte, bool) {
	return _chain_baked_base_for_ns(s, ns)
}

@(private = "file")
_chain_baked_base_for_ns :: proc(s: ^Scene, ns: ^NestedScene) -> ([]byte, bool) {
	if s == nil || ns == nil do return nil, false

	// Baseline = the prefab RESOLVED (variant inheritance flattened: base +
	// the variant's own overrides + additions). For a flat prefab this is its
	// raw bytes. Using raw here would diff against an unresolved variant file
	// and lose overrides on nested-variant content.
	prefab_raw, owned := _prefab_resolved_bytes(ns.source_prefab)
	if prefab_raw == nil do return nil, false
	defer if owned do delete(prefab_raw)

	clone_raw :: proc(src: []byte) -> []byte {
		out := make([]byte, len(src))
		copy(out, src)
		return out
	}

	if ns.expand_parent == {} {
		return clone_raw(prefab_raw), true
	}

	// Build the chain of (outer_prefab_guid, transform_parent_in_outer) hops
	// from `ns` outward to root, then walk in reverse (outermost-first) and at
	// each level apply that level's outer prefab's NS-for-(next inner)
	// overrides to the next prefab raw. The final result is `ns.source_prefab`
	// raw with every level's overrides on top.
	// The hop identifies the child NS's RECORD IN THE OUTER FILE by its
	// file-stable lid (local_id_in_parent) — runtime metadata like
	// transform_parent is projected into the host namespace and no longer
	// matches file values.
	Hop :: struct { outer_guid: Asset_GUID, child_guid: Asset_GUID, child_ns_file_lid: Local_ID }
	hops := make([dynamic]Hop, 0, 4, context.temp_allocator)

	cur := ns
	for _ in 0 ..< 64 {
		ep := cur.expand_parent
		if ep == {} do break
		outer := scene_find_nested_scene_for_host(s, ep)
		if outer == nil do return nil, false
		append(&hops, Hop{
			outer_guid        = outer.source_prefab,
			child_guid        = cur.source_prefab,
			child_ns_file_lid = _ns_projection_key(cur),
		})
		cur = outer
	}

	// Walk hops in reverse (outermost-first). Start with outermost prefab raw,
	// each iteration extracts the NS-for-child overrides and applies them to
	// the child prefab raw.
	cur_raw := prefab_raw  // last iteration produces ns.source_prefab raw + chain mods
	cur_owns := false

	for i := len(hops) - 1; i >= 0; i -= 1 {
		hop := hops[i]
		// RESOLVED outer bytes, not raw: when the outer prefab is a VARIANT,
		// its raw file has no NS records for the base's nested prefabs — those
		// live in the base file, and the variant's own deep overrides reach
		// them only in the flattened form (_prefab_resolved_bytes pushes them
		// down onto the inner NS records). Reading raw here silently skipped
		// that whole layer, so capture/revert baselines missed variant edits.
		outer_raw, outer_owned := _prefab_resolved_bytes(hop.outer_guid)
		if outer_raw == nil do return nil, false

		outer_copy := make([]byte, len(outer_raw), context.temp_allocator)
		copy(outer_copy, outer_raw)
		if outer_owned do delete(outer_raw)
		outer_sf: SceneFile
		if scene_file_unmarshal(outer_copy, &outer_sf) != nil do return nil, false

		matching: []Override
		for &m in outer_sf.nested_scenes {
			if m.source_prefab != hop.child_guid do continue
			if m.local_id != hop.child_ns_file_lid do continue
			matching = m.overrides[:]
			break
		}

		// Resolve the child prefab (flattening variant inheritance) before applying
		// the outer overrides — same reasoning as the top-level baseline above. A
		// flat prefab resolves to its own raw, so non-variant chains are unaffected.
		child_raw, child_owns := _prefab_resolved_bytes(hop.child_guid)
		if child_raw == nil {
			scene_file_destroy(&outer_sf)
			return nil, false
		}
		defer if child_owns do delete(child_raw)

		baked := nested_scene_apply_overrides(child_raw, matching)
		baked_owns := raw_data(baked) != raw_data(child_raw)
		next_buf: []byte
		if baked_owns {
			next_buf = baked
		} else {
			// no overrides at this level — copy so we own uniformly.
			next_buf = clone_raw(child_raw)
		}
		scene_file_destroy(&outer_sf)

		if cur_owns do delete(cur_raw)
		cur_raw = next_buf
		cur_owns = true
	}

	if !cur_owns do return clone_raw(cur_raw), true
	return cur_raw, true
}

// Captures root-scene overrides for `ns` directly into the open scene's root
// native NS. Diffs `ns`'s prefab-chain-baked base against the live
// nested-owned subtree; each resulting (target, property_path, value) is
// emitted onto the **native** NS that owns this chain (with target rewritten
// to a breadcrumb local_id when `ns` is an inner NS, or kept as the prefab
// lid when `ns` IS native). Inner-NS records never accumulate overrides under
// this design — they are runtime artifacts only.
//
// Caller is responsible for clearing native_ns.overrides BEFORE the first
// call across all NS records, and for clearing every NS's overrides AFTER
// (the inner ones must end up empty so resolve and serialization see a
// consistent picture).
@(private = "file")
// Rewrites every "local_id" number in a parsed JSON doc through `m` (misses
// pass through). Record identities and Ref_Local/PPtr values all serialize
// under that key, so one rule un-projects a collected live doc back to source
// namespace for override capture (Unity: modifications target source fileIDs).
// JSON-level on purpose: the collected SceneFile shallow-copies live components,
// so struct-level remapping could write through shared dynamic arrays.
_json_remap_lids :: proc(v: json.Value, m: ^map[Local_ID]Local_ID) {
	#partial switch obj in v {
	case json.Object:
		for k, &val in obj {
			if k == "local_id" {
				#partial switch num in val {
				case json.Integer:
					if src, ok := m^[Local_ID(num)]; ok do val = json.Integer(src)
				case json.Float:
					if src, ok := m^[Local_ID(i64(num))]; ok do val = json.Float(f64(src))
				}
				continue
			}
			_json_remap_lids(val, m)
		}
	case json.Array:
		for &elem in obj {
			_json_remap_lids(elem, m)
		}
	}
}

_capture_overrides_to_native :: proc(s: ^Scene, ns: ^NestedScene) {
	w := ctx_world()
	if ns.source_prefab == (Asset_GUID{}) do return

	host_tH := nested_scene_resolve_host_handle(s, ns)
	if host_tH == {} do return
	host_t := pool_get(&w.transforms, Handle(host_tH))
	if host_t == nil do return

	// Resolved prefab bytes (variant inheritance flattened) — used for the base
	// root id and the missing-target cleanup, both of which must see the
	// variant's full resolved lid set, not the raw variant file.
	prefab_raw, prefab_raw_owned := _prefab_resolved_bytes(ns.source_prefab)
	if prefab_raw == nil do return
	defer if prefab_raw_owned do delete(prefab_raw)

	prefab_root_id: Local_ID
	{
		prefab_copy := make([]byte, len(prefab_raw), context.temp_allocator)
		copy(prefab_copy, prefab_raw)
		base_sf: SceneFile
		if scene_file_unmarshal(prefab_copy, &base_sf) == nil {
			prefab_root_id = base_sf.root
			scene_file_destroy(&base_sf)
		}
	}

	work_sf := SceneFile{}
	work_sf.root = prefab_root_id != 0 ? prefab_root_id : host_t.local_id
	_collect_nested_owned_subtree(w, host_tH, &work_sf, prefab_root_id, ns, host_tH)
	defer scene_file_destroy_shallow(&work_sf)

	work_marshaled, werr := json.marshal(work_sf, json.Marshal_Options{spec = .JSON, pretty = false}, context.temp_allocator)
	if werr != nil {
		fmt.printf("[Scene] Failed to marshal working copy for override capture: %v\n", werr)
		return
	}

	// The live instance carries composed instance lids; the diff baseline is
	// the prefab file — un-project the working doc to source namespace.
	work_val: json.Value
	if json.unmarshal(work_marshaled, &work_val, .JSON, context.temp_allocator) != nil do return
	_json_remap_lids(work_val, &ns.source_of_inst)
	work_raw, rerr := json.marshal(work_val, json.Marshal_Options{spec = .JSON, pretty = false})
	if rerr != nil do return
	defer delete(work_raw)

	base_raw, ok := _chain_baked_base_for_ns(s, ns)
	if !ok do return
	defer delete(base_raw)

	// Normalize the prefab base's component records to the live struct field
	// set: a prefab authored before a component gained a field omits that key,
	// but the live content always serializes it — without this, an unchanged
	// save captures every such field as a spurious override.
	diff_base := base_raw
	if normalized, nok := _normalize_component_records(base_raw); nok do diff_base = normalized

	diff := nested_scene_diff_overrides(diff_base, work_raw, ns.source_prefab)
	defer {
		// `diff` ownership is transferred into native_ns.overrides (or freed if
		// any entries are skipped); destroy the dynamic-array shell at end.
		delete(diff)
	}

	_drop_overrides_with_missing_targets(&diff, prefab_raw)

	// Locate the native NS that owns the override list. Inner NSs aren't
	// persisted — overrides on them flow up to the enclosing native NS as
	// breadcrumb-keyed deep overrides.
	native_ns: ^NestedScene = ns
	if ns.expand_parent != {} {
		_, nat_ns, chok := _inner_chain_to_native(s, ns)
		if !chok || nat_ns == nil {
			for &ov in diff {
				delete(ov.property_path)
				json.destroy_value(ov.value)
			}
			return
		}
		native_ns = nat_ns
	}

	// Pre-compute the inner-NS chain for projection. Top-down: chain[0] is the
	// outermost inner NS's local_id_in_parent (immediately under native_ns),
	// chain[last] is `ns`'s. Empty when ns IS native (shallow case).
	chain_lids: [dynamic]Local_ID
	if ns.expand_parent != {} {
		ch, _, chok := _inner_chain_lids_to_native(s, ns)
		if !chok {
			for &ov in diff {
				delete(ov.property_path)
				json.destroy_value(ov.value)
			}
			return
		}
		chain_lids = ch
	}

	for &ov in diff {
		// Diff stamped target = (ns.source_prefab, lid_in_inner_prefab).
		// For native NSs (no chain) this is the final shape. For inner NSs we
		// project lid_in_inner_prefab up through each enclosing inner NS's
		// local_id_in_parent so same-prefab-instantiated-twice produces
		// distinct projections; target.guid stays as `ns.source_prefab` (the
		// deepest prefab the field lives in, regardless of chain depth).
		final_target := ov.target
		if ns.expand_parent != {} {
			projected := ov.target.local_id
			for i := len(chain_lids) - 1; i >= 0; i -= 1 {
				projected = local_id_project(chain_lids[i], projected)
			}
			final_target.local_id = projected
		}

		// Append on native NS, deduping (target, property_path).
		dup := false
		for &existing in native_ns.overrides {
			if pptr_equals(existing.target, final_target) && existing.property_path == ov.property_path {
				dup = true
				break
			}
		}
		if dup {
			delete(ov.property_path)
			json.destroy_value(ov.value)
			continue
		}
		append(&native_ns.overrides, Override{
			target        = final_target,
			property_path = ov.property_path,
			value         = ov.value,
		})
	}
}

// Returns the set of local_ids that appear in the prefab base file's section
// arrays. Used by the override cleanup pass.
_collect_prefab_local_ids :: proc(base_raw: []byte, allocator := context.allocator) -> (map[Local_ID]bool, bool) {
	out := make(map[Local_ID]bool, 0, allocator)
	base_copy := make([]byte, len(base_raw), context.temp_allocator)
	copy(base_copy, base_raw)
	val: json.Value
	if json.unmarshal_string(string(base_copy), &val) != nil {
		delete(out)
		return nil, false
	}
	defer json.destroy_value(val)
	root, is_obj := val.(json.Object)
	if !is_obj {
		delete(out)
		return nil, false
	}
	for _, section_val in root {
		arr, is_arr := section_val.(json.Array)
		if !is_arr do continue
		for item in arr {
			obj, ok := item.(json.Object)
			if !ok do continue
			lid, lid_ok := _scene_file_local_id_of(obj)
			if lid_ok do out[lid] = true
		}
	}
	return out, true
}

_scene_file_local_id_of :: proc(obj: json.Object) -> (Local_ID, bool) {
	from_value :: proc(v: json.Value) -> (Local_ID, bool) {
		if f, ok := v.(json.Float);   ok do return Local_ID(f), true
		if i, ok := v.(json.Integer); ok do return Local_ID(i), true
		return 0, false
	}
	if v, ok := obj["local_id"]; ok do return from_value(v)
	if bv, ok := obj["base"]; ok {
		if bo, ok2 := bv.(json.Object); ok2 {
			if v, ok3 := bo["local_id"]; ok3 do return from_value(v)
		}
	}
	return 0, false
}

_drop_overrides_with_missing_targets :: proc(overrides: ^[dynamic]Override, base_raw: []byte) {
	ids, ok := _collect_prefab_local_ids(base_raw)
	if !ok do return
	defer delete(ids)
	write := 0
	for i in 0 ..< len(overrides) {
		ov := overrides[i]
		if ids[ov.target.local_id] {
			overrides[write] = ov
			write += 1
		} else {
			delete(ov.property_path)
			json.destroy_value(ov.value)
		}
	}
	resize(overrides, write)
}

_find_ns_by_local_id :: proc(s: ^Scene, ns_local_id: Local_ID) -> (^NestedScene, bool) {
	for &ns in s.nested_scenes {
		if ns.local_id == ns_local_id do return &ns, true
	}
	return nil, false
}

// Walks `inner_m`'s ancestry (via expand_parent) and returns the chain of
// prefab hops from the native NS down to (but not including) `inner_m`'s own
// hop, plus the native NS itself. The chain is top-down: chain[0] is the
// hop from the native NS into the next inner level. Each entry is a PPtr
// (prefab guid, host transform local_id in PARENT prefab namespace).
// Public wrapper around the file-private chain walker. Used by Ref_Local
// picker assignment to build the (native_ns, scene_path) tuple needed for
// breadcrumb_create when the chosen target is nested-owned.
_inner_chain_to_native_public :: proc(s: ^Scene, inner_m: ^NestedScene) -> ([dynamic]PPtr, ^NestedScene, bool) {
	return _inner_chain_to_native(s, inner_m)
}

// Public wrapper around the lid-collecting chain walker. Returns the chain of
// inner NS local_id_in_parent values from inner_m up to (but not including)
// native, top-down. Used by the Ref_Local picker to project the chosen
// target's lid the same way override capture does.
_inner_chain_lids_to_native_public :: proc(s: ^Scene, inner_m: ^NestedScene) -> ([dynamic]Local_ID, ^NestedScene, bool) {
	return _inner_chain_lids_to_native(s, inner_m)
}

// Returns the chain of inner NS `local_id_in_parent` values from `inner_m`
// up to (but not including) the native NS, top-down: chain[0] is the
// outermost inner NS's local_id_in_parent, chain[last] is `inner_m`'s. Used
// as the projection key sequence for Unity-style XOR-encoded deep targets.
_inner_chain_lids_to_native :: proc(s: ^Scene, inner_m: ^NestedScene) -> ([dynamic]Local_ID, ^NestedScene, bool) {
	chain := make([dynamic]Local_ID, 0, 4, context.temp_allocator)
	if inner_m == nil || inner_m.expand_parent == {} do return chain, nil, false
	w := ctx_world()

	append(&chain, _ns_projection_key(inner_m))

	cur := inner_m
	for _ in 0 ..< 32 {
		ep := cur.expand_parent
		if ep == {} do return chain, nil, false
		et := pool_get(&w.transforms, Handle(ep))
		if et == nil do return chain, nil, false
		if !et.nested_owned {
			for &n2 in s.nested_scenes {
				if n2.expand_parent != {} do continue
				if !nested_scene_hosts_transform(s, &n2, ep) do continue
				n := len(chain)
				for i in 0 ..< n / 2 {
					chain[i], chain[n - 1 - i] = chain[n - 1 - i], chain[i]
				}
				return chain, &n2, true
			}
			return chain, nil, false
		}
		next: ^NestedScene = nil
		for &n2 in s.nested_scenes {
			if n2.expand_parent == {} do continue
			if nested_scene_hosts_transform(s, &n2, ep) {
				next = &n2
				break
			}
		}
		if next == nil do return chain, nil, false
		append(&chain, _ns_projection_key(next))
		cur = next
	}
	return chain, nil, false
}

@(private = "file")
_inner_chain_to_native :: proc(s: ^Scene, inner_m: ^NestedScene) -> ([dynamic]PPtr, ^NestedScene, bool) {
	chain := make([dynamic]PPtr, 0, 4, context.temp_allocator)
	if inner_m == nil || inner_m.expand_parent == {} do return chain, nil, false
	w := ctx_world()

	// Walk: append `inner_m`'s OWN hop first, then walk up adding each
	// outer inner_m's hop. Stop at the native level.
	append(&chain, PPtr{local_id = inner_m.transform_parent, guid = inner_m.source_prefab})

	cur := inner_m
	for _ in 0 ..< 32 {
		ep := cur.expand_parent
		if ep == {} do return chain, nil, false
		et := pool_get(&w.transforms, Handle(ep))
		if et == nil do return chain, nil, false
		if !et.nested_owned {
			// ep belongs to the native scene — find its native NS.
			for &n2 in s.nested_scenes {
				if n2.expand_parent != {} do continue
				if !nested_scene_hosts_transform(s, &n2, ep) do continue
				// Reverse so chain becomes top-down.
				n := len(chain)
				for i in 0 ..< n / 2 {
					chain[i], chain[n - 1 - i] = chain[n - 1 - i], chain[i]
				}
				return chain, &n2, true
			}
			return chain, nil, false
		}
		// ep is a nested-owned host transform — owner must be another inner NS.
		next: ^NestedScene = nil
		for &n2 in s.nested_scenes {
			if n2.expand_parent == {} do continue
			if nested_scene_hosts_transform(s, &n2, ep) {
				next = &n2
				break
			}
		}
		if next == nil do return chain, nil, false
		append(&chain, PPtr{local_id = next.transform_parent, guid = next.source_prefab})
		cur = next
	}
	return chain, nil, false
}

// Serializes the scene's CURRENT in-memory state to scene-file bytes without
// touching disk or any caches. Runs the same normalization a save does
// (override recapture, orphan pruning, next_local_id repair). Caller owns the
// returned bytes. Used by scene_save and by Play's live-state snapshot.
scene_serialize :: proc(s: ^Scene) -> ([]byte, bool) {
	if s == nil do return nil, false
	w := ctx_world()

	// Per docs/NestedPrefabs.md, overrides live at the root scene level only.
	// Capture writes directly onto each chain's native NS; inner-NS records
	// keep the overrides they loaded from their inner-prefab files (those are
	// runtime-only — used by per-level shallow bake during resolve, never
	// persisted by save's filter). Clear native NS overrides so the diff
	// repopulates from scratch.
	for &ns in s.nested_scenes {
		if ns.expand_parent != {} do continue
		for &ov in ns.overrides {
			delete(ov.property_path)
			json.destroy_value(ov.value)
		}
		clear(&ns.overrides)
	}
	for &ns in s.nested_scenes {
		_capture_overrides_to_native(s, &ns)
	}

	// Prune orphan breadcrumbs whose owning NS no longer references them as a
	// host peg. Cross-scene Handle pegs (no NS owner) are left alone — they're
	// referenced via Handle/PPtr fields elsewhere. Breadcrumbs whose bimap
	// entry has been bound to a real runtime handle (type_key != INVALID_TYPE_KEY)
	// are also kept: those were created by the Ref_Local picker for a
	// nested-owned target and the reference is live.
	{
		ns_referenced := make(map[Local_ID]bool, 0, context.temp_allocator)
		for &ns in s.nested_scenes {
			if ns.host_breadcrumb_id != 0 do ns_referenced[ns.host_breadcrumb_id] = true
		}
		to_drop := make([dynamic]Local_ID, 0, 8, context.temp_allocator)
		for lid, bc in s.breadcrumb_data {
			if _, has_owner := _find_ns_by_local_id(s, bc.scene_instance); !has_owner do continue
			if ns_referenced[lid] do continue
			if h, ok := bimap_get(&s.local_ids, lid); ok && h.type_key != INVALID_TYPE_KEY do continue
			append(&to_drop, lid)
		}
		for lid in to_drop do breadcrumb_remove(s, lid)
	}

	sf := SceneFile{}
	sf.next_local_id = s.next_local_id

	// Only persist NS records that belong to this scene file. Records with
	// `expand_parent` set were pulled in from inner prefabs during resolve
	// (see nested_scene_resolve at nested_scene.odin:582) and live in
	// `s.nested_scenes` purely for in-memory operations — saving them would
	// duplicate the inner prefab's metadata into this file and, on reload,
	// turn the inner host transforms into ghost nested-scene hosts.
	native_ns_lids := make(map[Local_ID]bool, 0, context.temp_allocator)
	root_variant_ns_lid := Local_ID(0)
	for &ns in s.nested_scenes {
		if ns.expand_parent != {} do continue
		// Prune ORPHAN NS records: a native NS whose host transform no longer
		// exists is leaked metadata (e.g. the host was deleted but the record
		// wasn't). Persisting it produces a ghost host on reload — this is how
		// bullet.scene accumulated a phantom bullet_Variant NS. Root variants
		// (host == s.root) are always valid.
		if !nested_scene_is_root_variant(s, &ns) {
			if nested_scene_resolve_host_handle(s, &ns) == {} {
				fmt.printf("[Scene] pruning orphan NS lid=%d src=%v (no host transform)\n", ns.local_id, ns.source_prefab)
				continue
			}
		}
		rec := ns
		// A variant's root NS is hosted by a synthesized placeholder root that
		// is NOT persisted. Write it back in its on-disk shape: transform_parent
		// == 0 (the variant marker) and no host breadcrumb.
		if nested_scene_is_root_variant(s, &ns) {
			rec.transform_parent = 0
			rec.host_breadcrumb_id = 0
			root_variant_ns_lid = ns.local_id
		}
		append(&sf.nested_scenes, rec)
		native_ns_lids[ns.local_id] = true
	}
	for _, bc in s.breadcrumb_data {
		// The root-variant NS's host peg points at the synthesized placeholder,
		// which isn't persisted — drop it (the on-disk record has no host).
		if root_variant_ns_lid != 0 && bc.scene_instance == root_variant_ns_lid do continue
		// Keep only breadcrumbs whose owning NestedScene is also native (or
		// that aren't host pegs at all — cross-scene Handle pegs survive).
		if native_ns_lids[bc.scene_instance] {
			append(&sf.breadcrumbs, bc)
		} else if _, has_owner := _find_ns_by_local_id(s, bc.scene_instance); !has_owner {
			append(&sf.breadcrumbs, bc)
		}
	}

	if s.root.handle != {} {
		t := pool_get(&w.transforms, s.root.handle)
		if t != nil {
			// Variant case: the scene root is a synthesized placeholder hosting
			// the root-variant NS. Don't write the placeholder or the base's
			// transforms (they live in the base file) — only the variant's own
			// ADDED content (non-nested-owned transforms under the base subtree).
			// sf.root names the base root source lid so reload re-materializes
			// the base via the (transform_parent: 0) root NS.
			root_ns: ^NestedScene
			for &ns in s.nested_scenes {
				if nested_scene_is_root_variant(s, &ns) {
					root_ns = &ns
					break
				}
			}
			if root_ns != nil {
				sf.root = root_ns.source_root_id != 0 ? root_ns.source_root_id : t.local_id
				_collect_variant_added_subtree(w, Transform_Handle(s.root.handle), &sf, Transform_Handle(s.root.handle), sf.root)
			} else {
				sf.root = t.local_id
				_collect_transform_tree(w, Transform_Handle(s.root.handle), &sf)
			}
		}
	}

	// Unknown components preserved from load:
	// re-emit each record verbatim and restore the owning transform's
	// components entry — a missing package must never wipe data. A record
	// whose transform is gone from the file dies with it (deleted transform).
	for &uc in s.unknown_components {
		for &tr in sf.transforms {
			if tr.local_id != uc.owner_lid do continue
			append(&tr.components, Owned{local_id = uc.local_id})
			append(&sf.components, json.clone_value(uc.value))
			break
		}
	}

	// Repair next_local_id: any local_id present in the file must be strictly
	// less than next_local_id. Otherwise a future scene_next_id() collides with
	// an existing entity, which on reload can cause a regular transform to be
	// matched as the host of a NestedScene record.
	bump :: proc(m: ^Local_ID, v: Local_ID) { if v >= m^ do m^ = v + 1 }
	for &tr in sf.transforms {
		bump(&sf.next_local_id, tr.local_id)
		for &c in tr.components do bump(&sf.next_local_id, c.local_id)
	}
	for &ns in sf.nested_scenes   do bump(&sf.next_local_id, ns.local_id)
	for &bc in sf.breadcrumbs     do bump(&sf.next_local_id, bc.local_id)
	s.next_local_id = sf.next_local_id

	opts := json.Marshal_Options{
		spec       = .JSON,
		pretty     = true,
		use_spaces = true,
		spaces     = 2,
		// Deterministic key order for json.Object values (ext components):
		// "__type" sorts before lowercase field names, so it leads each record.
		sort_maps_by_key = true,
	}
	data, err := json.marshal(sf, opts)
	if err != nil {
		fmt.printf("[Scene] Failed to marshal scene: %v\n", err)
		scene_file_destroy_shallow(&sf)
		return nil, false
	}

	scene_file_destroy_shallow(&sf)
	return data, true
}

scene_save :: proc(s: ^Scene, path: string) -> bool {
	data, ok := scene_serialize(s)
	if !ok do return false
	defer delete(data)

	if write_err := os.write_entire_file(path, data); write_err != nil {
		fmt.printf("[Scene] Failed to write file: %s — %v\n", path, write_err)
		return false
	}

	if s.path != path {
		delete(s.path)
		s.path = strings.clone(path)
	}

	// Per docs/NestedPrefabs.md "Changes propagation": saving a prefab walks
	// all live `NestedScene` records whose `source_prefab` GUID matches the
	// saved asset and reloads them. Refresh `scene_lib`'s cached bytes for
	// this asset, drop the unpacked-snapshot cache, and re-resolve every
	// native NS whose chain transitively contains this guid in any loaded
	// scene — including the scene we just saved (its own nested instances of
	// itself, if any, plus any sibling NSs that depend on it via inner chain).
	if guid, gok := asset_db_get_guid(path); gok {
		_prefab_bytes_committed(Asset_GUID(guid), data)
	}

	// Keep the AssetDB current: a save can change the root's components (picker
	// index) or create the file (Save As). Incremental — unchanged assets cost
	// nothing. Skipped when no db is initialized (headless scene tooling).
	if asset_db.root_path != "" {
		asset_db_refresh()
	}

	fmt.printf("[Scene] Saved scene to %s\n", path)
	return true
}

// Authors a prefab-variant scene file at `out_path` whose root is a NestedScene
// over the base scene at `base_path` (transform_parent == 0, no overrides, no
// added content). Mirrors the on-disk shape produced by saving a variant. The
// caller is responsible for refreshing AssetDB so the new file gets a .meta and
// for loading it. Returns false if the base can't be read or has no GUID.
scene_create_variant_file :: proc(base_path: string, out_path: string) -> bool {
	base_guid, gok := asset_db_get_guid(base_path)
	if !gok do return false

	base_sf, lok := scene_file_load(base_path)
	if !lok do return false
	base_root_lid := base_sf.root
	scene_file_destroy(&base_sf)
	if base_root_lid == 0 do return false

	// Build a minimal variant SceneFile: one root NS, no own transforms. `root`
	// references the base root lid so reload re-materializes the base via the
	// root-variant load path. Local ids for the NS sit above the base's
	// namespace to avoid colliding with materialized base lids.
	ns_lid := base_root_lid + 1000
	vf := SceneFile{}
	vf.root = base_root_lid
	vf.next_local_id = ns_lid + 1
	append(&vf.nested_scenes, NestedScene{
		local_id           = ns_lid,
		local_id_in_parent = ns_lid,
		source_prefab      = Asset_GUID(base_guid),
		transform_parent   = 0,
		host_breadcrumb_id = 0,
		sibling_index      = 0,
		overrides          = make([dynamic]Override),
	})
	defer scene_file_destroy(&vf)

	opts := json.Marshal_Options{spec = .JSON, pretty = true, use_spaces = true, spaces = 2}
	data, err := json.marshal(vf, opts)
	if err != nil {
		fmt.printf("[Scene] Failed to marshal variant: %v\n", err)
		return false
	}
	defer delete(data)

	if write_err := os.write_entire_file(out_path, data); write_err != nil {
		fmt.printf("[Scene] Failed to write variant file: %s — %v\n", out_path, write_err)
		return false
	}
	return true
}

// Refreshes the in-memory caches for a prefab GUID after its file bytes
// changed on disk, then re-propagates to every loaded scene. Shared by
// scene_save (saving a prefab) and nested_scene_apply_override (baking an
// override into a parent prefab). `data` is copied — caller retains ownership.
_prefab_bytes_committed :: proc(guid: Asset_GUID, data: []byte) {
	_prefab_bytes_refresh(guid, data)
	_propagate_prefab_save(guid)
}

// Cache-only half of `_prefab_bytes_committed`: refresh `scene_lib` bytes and
// drop the unpacked snapshot WITHOUT re-propagating. Lets a caller mutate
// several prefab files (and its own in-memory NS state) before triggering a
// single propagation pass — avoids re-resolving against a half-updated world.
_prefab_bytes_refresh :: proc(guid: Asset_GUID, data: []byte) {
	// scene_lib is process-global — its bytes must not borrow the caller's
	// allocator (see scene_lib_register).
	context.allocator = runtime.default_allocator()
	if existing, has := scene_lib[guid]; has do delete(existing)
	// scene_lib holds the unified "components" record format only — migrate
	// legacy bytes at intake, same as scene_lib_register.
	fresh: []byte
	if _scene_file_is_legacy(data) {
		if migrated, mok := _scene_file_migrate_legacy(data); mok {
			fresh = migrated
		}
	}
	if fresh == nil {
		fresh = make([]byte, len(data))
		copy(fresh, data)
	}
	scene_lib[guid] = fresh
	scene_lib_unpacked_invalidate(guid)
}

// Re-resolve pass for a saved/edited prefab guid. Exposed for Apply's deferred
// propagation. (`_propagate_prefab_save` is file-private to scene_file.odin.)
prefab_propagate :: proc(guid: Asset_GUID) {
	_propagate_prefab_save(guid)
}

// Walks all loaded scenes and re-resolves every native NS whose chain
// transitively contains `saved_guid`. "Contains" means the native NS itself
// has source_prefab == saved_guid, OR any inner NS under it (any NS with
// expand_parent in that native's resolved subtree) has source_prefab ==
// saved_guid. Re-resolving the native rebuilds its entire subtree, picking
// up the freshly-saved prefab content.
@(private = "file")
_propagate_prefab_save :: proc(saved_guid: Asset_GUID) {
	// No user context (e.g. asset_db_init before a world exists) means no
	// loaded scenes to propagate into.
	if ctx_get() == nil do return
	sm := ctx_scene_manager()
	for i in 0 ..< sm.count {
		s := sm.loaded[i]
		if s == nil do continue

		// Collect native NS local_ids whose chain involves saved_guid.
		to_reresolve := make([dynamic]Local_ID, 0, 8, context.temp_allocator)
		for &ns in s.nested_scenes {
			if ns.source_prefab != saved_guid do continue
			// Walk to the native ancestor.
			cur := &ns
			if cur.expand_parent == {} {
				append(&to_reresolve, cur.local_id)
				continue
			}
			for _ in 0 ..< 64 {
				ep := cur.expand_parent
				if ep == {} {
					append(&to_reresolve, cur.local_id)
					break
				}
				outer := scene_find_nested_scene_for_host(s, ep)
				if outer == nil do break
				if outer.expand_parent == {} {
					append(&to_reresolve, outer.local_id)
					break
				}
				cur = outer
			}
		}

		// Dedup.
		seen := make(map[Local_ID]bool, 0, context.temp_allocator)
		for lid in to_reresolve {
			if seen[lid] do continue
			seen[lid] = true
			ns_ptr, has := scene_nested_scene_by_local_id(s, lid)
			if !has || ns_ptr == nil do continue
			host_tH := nested_scene_resolve_host_handle(s, ns_ptr)
			if host_tH == {} do continue
			nested_scene_resolve(host_tH)
		}
	}
}

scene_file_load :: proc(filepath: string) -> (SceneFile, bool) {
	data, read_ok := os.read_entire_file(filepath, context.allocator)
	if read_ok != nil {
		fmt.printf("[Scene] Failed to read file: %s\n", filepath)
		return {}, false
	}
	defer delete(data)

	sf: SceneFile
	unmarshal_err := scene_file_unmarshal(data, &sf)
	if unmarshal_err != nil {
		fmt.printf("[Scene] Failed to unmarshal scene: %v\n", unmarshal_err)
		return {}, false
	}

	return sf, true
}

// --- Legacy scene format migration -------------
// Pre-unification scene files carried one TYPED array per engine component
// section plus "ext_components"; the unified format is ONE "components" array
// of guid-tagged records. Load-time migration folds legacy sections into
// records so old files keep loading; saving writes the unified format. The
// section-name → guid table is CLOSED — typed sections can never reappear.

_Legacy_Section :: struct {
	name: string,
	guid: string,
}

_LEGACY_SECTIONS :: [?]_Legacy_Section{
	{"animations",            "5b8c2f4e-1d3a-4e6b-8f90-7a2c4d6e8b13"}, // Animation
	{"cameras",               "7a3b9c1d-2e4f-5a6b-8c7d-9e0f1a2b3c4d"}, // Camera
	{"lights",                "9f36ee91-34b6-4636-a360-ee872af0436b"}, // Light
	{"mesh_filters",          "32f52908-51a9-4f3b-819b-fc9d8cbc5972"}, // MeshFilter
	{"mesh_renderers",        "73e161a0-c599-4cfb-9826-447e05baa76c"}, // MeshRenderer
	{"scripts",               "adaf3551-4704-4255-ad91-fde59441dc53"}, // Script
	{"sprite_renderers",      "b7e2a1c3-5d4f-4e8a-9f1b-3c6d8e0a2b4f"}, // SpriteRenderer
	{"sprite_sorting_groups", "2291f857-d2ff-409d-96df-1d87713fdcc2"}, // SpriteSortingGroup
	{"players",               "d3f1a2b4-7e8c-4d5f-9a0b-1c2e3f4a5b6c"}, // Player (moved to packages/app)
	{"lifetimes",             "c3a1e4f2-7b8d-4a2e-9c5f-1d6e3b0f7a8c"}, // Lifetime (moved to packages/app)
}

// Cheap pre-check: quoted section keys only appear in legacy files (a false
// positive from a same-named nested field just triggers a harmless parse).
_scene_file_is_legacy :: proc(data: []byte) -> bool {
	text := string(data)
	if strings.contains(text, "\"ext_components\"") do return true
	sections := _LEGACY_SECTIONS
	for s in sections {
		key := fmt.tprintf("%q", s.name)
		if strings.contains(text, key) do return true
	}
	return false
}

// SceneFile unmarshal front door: EVERY byte→SceneFile path goes through
// here so legacy files migrate uniformly.
scene_file_unmarshal :: proc(data: []byte, sf: ^SceneFile) -> json.Unmarshal_Error {
	// On error, json.unmarshal leaves already-populated fields allocated —
	// free the partial result so callers can just bail.
	unmarshal_owning :: proc(data: []byte, sf: ^SceneFile) -> json.Unmarshal_Error {
		err := json.unmarshal(data, sf)
		if err != nil {
			scene_file_destroy(sf)
			sf^ = {}
		}
		return err
	}
	if !_scene_file_is_legacy(data) {
		return unmarshal_owning(data, sf)
	}
	migrated, ok := _scene_file_migrate_legacy(data)
	if !ok {
		return unmarshal_owning(data, sf) // fall through: parse errors surface normally
	}
	defer delete(migrated)
	return unmarshal_owning(migrated, sf)
}

// Fold legacy typed sections + "ext_components" into "components" at the JSON
// level and re-marshal (context.allocator result).
_scene_file_migrate_legacy :: proc(data: []byte) -> ([]byte, bool) {
	// All intermediate JSON work is temp — only the marshaled result goes to
	// the caller's allocator.
	out_allocator := context.allocator
	context.allocator = context.temp_allocator
	root, perr := json.parse(data, .JSON, true, context.temp_allocator)
	if perr != nil do return nil, false
	obj, is_obj := root.(json.Object)
	if !is_obj do return nil, false

	components: json.Array
	if existing, has := obj["components"]; has {
		if arr, is_arr := existing.(json.Array); is_arr do components = arr
	}

	move_section :: proc(obj: ^json.Object, name: string, guid: string, components: ^json.Array) {
		v, has := obj[name]
		if !has do return
		if arr, is_arr := v.(json.Array); is_arr {
			for rec in arr {
				rec_obj, rec_is_obj := rec.(json.Object)
				if !rec_is_obj do continue
				if guid != "" {
					rec_obj[strings.clone(EXT_TYPE_KEY, context.temp_allocator)] = json.String(guid)
				}
				append(components, json.Value(rec_obj))
			}
		}
		delete_key(obj, name)
	}

	sections := _LEGACY_SECTIONS
	for s in sections {
		move_section(&obj, s.name, s.guid, &components)
	}
	move_section(&obj, "ext_components", "", &components) // records already tagged

	obj["components"] = json.Value(components)

	out, merr := json.marshal(json.Value(obj), {spec = .JSON}, out_allocator)
	if merr != nil do return nil, false
	return out, true
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

	scene_guid: Asset_GUID = {}
	if g, gok := asset_db_get_guid(path); gok {
		scene_guid = Asset_GUID(g)
	}
	s := _scene_load_single(&sf, scene_guid)
	if s != nil {
		s.path = strings.clone(path)
	}
	return s
}

scene_load_additive_path :: proc(path: string) -> ^Scene {
	sf, ok := scene_file_load(path)
	if !ok do return nil
	defer scene_file_destroy(&sf)

	scene_guid: Asset_GUID = {}
	if g, gok := asset_db_get_guid(path); gok {
		scene_guid = Asset_GUID(g)
	}
	s := _scene_load_additive(&sf, scene_guid)
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
	defer scene_file_destroy_shallow(&sf)

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
	if err := scene_file_unmarshal(data, &sf); err != nil {
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
