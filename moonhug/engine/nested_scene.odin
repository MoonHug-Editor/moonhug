package engine

import "core:encoding/json"
import "core:strings"
import "core:reflect"
import "core:os"
import "core:fmt"
import "core:encoding/uuid"

// Unity-style override target: a PPtr directly carrying (deepest_prefab_guid,
// projected_lid). The owning NestedScene supplies the implicit `scene_instance`,
// matching Unity's PrefabInstance.m_Modifications[i].target = {fileID, guid}.
//
// For shallow overrides (the target lives in `ns.source_prefab`), `target.guid`
// equals `ns.source_prefab` and `target.local_id` is the row's lid in that prefab.
//
// For deep overrides (target lives N levels below `ns.source_prefab`),
// `target.guid` names the deepest prefab and `target.local_id` is the leaf
// prefab-namespace lid XOR-projected through every inner NS's
// `local_id_in_parent` on the way up. Same-prefab-instantiated-twice yields
// distinct projected lids per outer instance.
Override :: struct {
    target:        PPtr,
    property_path: string,
    value:         json.Value,
}

// Breadcrumb is a stripped placeholder modeled after Unity's stripped objects.
// Each instance of a cross-scene Handle reference (deep override target,
// Ref_Local picker into a nested-owned object, NS host peg) gets a Breadcrumb
// in the host scene file. Resolution at load:
//   * (scene_instance, scene_source) → walk the runtime NS tree from the
//     anchor to find the matching destination.
//   * For depth-1 (target lives directly in scene_instance's source_prefab),
//     scene_source.guid == that prefab's GUID and scene_source.local_id is the
//     prefab-namespace lid.
//   * For depth-N (target lives N levels deep through inner NSs), scene_source
//     names the deepest prefab; resolution searches s.nested_scenes for an NS
//     descending from scene_instance whose source_prefab matches and contains
//     the target.
// LIMITATION: Same-prefab-instantiated-twice along one chain ambiguates. This
// matches Unity's model only when XOR projection is added (planned migration
// stages 2-3, see docs/UnityStyleMigration.md).
Breadcrumb :: struct {
    local_id:           Local_ID,  // referrer will use this local_id for resolving
    scene_source:       PPtr,      // final destination: (deepest prefab guid, local_id in that prefab)
    scene_instance:     Local_ID,  // local_id of NestedScene record this breadcrumb is anchored to
}

pptr_guid_is_empty :: proc(g: Asset_GUID) -> bool {
    return g == Asset_GUID{}
}

pptr_equals :: proc(a, b: PPtr) -> bool {
	return a.local_id == b.local_id && a.guid == b.guid
}

// Reads `local_id` directly off `obj`, falling back to `obj.base.local_id` when
// the row stores its identity under a wrapper. Used by overrides apply/diff and
// any other code walking serialized scene-section arrays.
@(private = "file")
_json_local_id_of :: proc(obj: json.Object) -> (Local_ID, bool) {
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

scene_file_remap_merge_metadata :: proc(sf: ^SceneFile, s: ^Scene) {
	if s == nil do return
	used := make(map[Local_ID]bool, context.temp_allocator)
	for lid, _ in s.local_ids.forward {
		used[lid] = true
	}
	for lid, _ in s.breadcrumb_data {
		used[lid] = true
	}
	for ns in s.nested_scenes {
		used[ns.local_id] = true
	}

	ns_remap := make(map[Local_ID]Local_ID, context.temp_allocator)
	for &ns in sf.nested_scenes {
		old := ns.local_id
		// Capture the file-stable lid before any potential remap. For NSs
		// loaded from a prefab file this preserves the prefab-namespace lid
		// used as the projection key in deep-target XOR encoding. For NSs
		// already carrying a non-zero local_id_in_parent (round-tripped via
		// outer scene file), keep the existing value.
		if ns.local_id_in_parent == 0 {
			ns.local_id_in_parent = old
		}
		if used[old] {
			new_id := scene_next_id(s)
			ns_remap[old] = new_id
			ns.local_id = new_id
			used[new_id] = true
		} else {
			used[old] = true
		}
	}

	for &bc in sf.breadcrumbs {
		if new_inst, ok := ns_remap[bc.scene_instance]; ok {
			bc.scene_instance = new_inst
		}
	}

	bc_remap := make(map[Local_ID]Local_ID, context.temp_allocator)
	for &bc in sf.breadcrumbs {
		old := bc.local_id
		if used[old] {
			new_id := scene_next_id(s)
			bc_remap[old] = new_id
			bc.local_id = new_id
			used[new_id] = true
		} else {
			used[old] = true
		}
	}

	for &ns in sf.nested_scenes {
		if new_bid, ok := bc_remap[ns.host_breadcrumb_id]; ok {
			ns.host_breadcrumb_id = new_bid
		}
	}
}

_json_get_path :: proc(obj: json.Object, path: string) -> (json.Value, bool) {
    dot := strings.index_byte(path, '.')
    key := path if dot < 0 else path[:dot]
    val, ok := obj[key]
    if !ok do return nil, false
    if dot < 0 do return val, true
    sub, is_obj := val.(json.Object)
    if !is_obj do return nil, false
    return _json_get_path(sub, path[dot+1:])
}

_json_set_path :: proc(obj: ^json.Object, path: string, value: json.Value, allocator := context.allocator) {
    dot := strings.index_byte(path, '.')
    if dot < 0 {
        if existing, ok := obj[path]; ok {
            json.destroy_value(existing)
            obj[path] = json.clone_value(value, allocator)
        } else {
            obj[strings.clone(path, allocator)] = json.clone_value(value, allocator)
        }
        return
    }
    key := path[:dot]
    sub_val, has_sub := obj[key]
    sub_obj: json.Object
    if has_sub {
        if so, is_obj := sub_val.(json.Object); is_obj {
            sub_obj = so
        } else {
            json.destroy_value(sub_val)
            sub_obj = make(json.Object, 4, allocator)
        }
    } else {
        sub_obj = make(json.Object, 4, allocator)
    }
    _json_set_path(&sub_obj, path[dot+1:], value, allocator)
    if has_sub {
        obj[key] = sub_obj
    } else {
        obj[strings.clone(key, allocator)] = sub_obj
    }
}

// Bakes shallow overrides into `raw` (the JSON bytes for the prefab whose GUID
// is `prefab_guid`). Deep overrides (those whose `target.guid` names some
// deeper prefab) are skipped — they get applied at the bake of their own
// level. If `prefab_guid` is the empty GUID, every override is treated as
// matching (used by tests that bake without an asset context).
nested_scene_apply_overrides :: proc(raw: []byte, overrides: []Override, prefab_guid: Asset_GUID = {}) -> []byte {
	if len(overrides) == 0 do return raw

	raw_copy := make([]byte, len(raw))
	defer delete(raw_copy)
	copy(raw_copy, raw)

	root_val: json.Value
	err := json.unmarshal_string(string(raw_copy), &root_val)
    if err != nil do return raw
    defer json.destroy_value(root_val)

    root_obj, is_obj := root_val.(json.Object)
    if !is_obj do return raw

    skip_filter := asset_guid_is_empty(prefab_guid)
    for ov in overrides {
        if !skip_filter && ov.target.guid != prefab_guid do continue
        for key, section_val in root_obj {
            arr, is_arr := section_val.(json.Array)
            if !is_arr do continue
            for item, idx in arr {
                obj, ok := item.(json.Object)
                if !ok do continue
                lid, lid_ok := _json_local_id_of(obj)
                if !lid_ok || lid != ov.target.local_id do continue
                _json_set_path(&obj, ov.property_path, ov.value)
                arr[idx] = obj
                root_obj[key] = arr
                break
            }
        }
    }

    opts := json.Marshal_Options{spec = .JSON, pretty = false}
    data, merr := json.marshal(root_obj, opts)
    if merr != nil do return raw
    return data
}

_json_values_equal :: proc(a, b: json.Value) -> bool {
    switch av in a {
    case json.Null:
        _, ok := b.(json.Null)
        return ok
    case json.Boolean:
        bv, ok := b.(json.Boolean)
        return ok && av == bv
    case json.Integer:
        #partial switch bv in b {
        case json.Integer: return av == bv
        case json.Float:   return f64(av) == bv
        }
        return false
    case json.Float:
        #partial switch bv in b {
        case json.Float:   return av == bv
        case json.Integer: return av == f64(bv)
        }
        return false
    case json.String:
        bv, ok := b.(json.String)
        return ok && av == bv
    case json.Array:
        bv, ok := b.(json.Array)
        if !ok || len(av) != len(bv) do return false
        for i in 0..<len(av) {
            if !_json_values_equal(av[i], bv[i]) do return false
        }
        return true
    case json.Object:
        bv, ok := b.(json.Object)
        if !ok || len(av) != len(bv) do return false
        for k, v in av {
            bval, has := bv[k]
            if !has || !_json_values_equal(v, bval) do return false
        }
        return true
    }
    return false
}

_DIFF_TOP_EXCLUDED  :: []string{"parent", "children", "components"}
_DIFF_ALWAYS_EXCLUDED :: []string{"local_id"}

_json_diff_objects :: proc(base_obj, work_obj: json.Object, prefix: string, target: PPtr, out: ^[dynamic]Override) {
    for key, work_val in work_obj {
        {
            excluded := false
            for ek in _DIFF_ALWAYS_EXCLUDED {
                if key == ek { excluded = true; break }
            }
            if excluded do continue
        }
        if prefix == "" {
            excluded := false
            for ek in _DIFF_TOP_EXCLUDED {
                if key == ek { excluded = true; break }
            }
            if excluded do continue
        }

        base_val, has_base := base_obj[key]
        full_path := prefix == "" ? key : strings.concatenate({prefix, ".", key}, context.temp_allocator)

        if !has_base {
            append(out, Override{
                target        = target,
                property_path = strings.clone(full_path),
                value         = json.clone_value(work_val),
            })
            continue
        }

        _, work_is_arr := work_val.(json.Array)
        _, base_is_arr := base_val.(json.Array)
        if work_is_arr || base_is_arr {
            if !_json_values_equal(base_val, work_val) {
                append(out, Override{
                    target        = target,
                    property_path = strings.clone(full_path),
                    value         = json.clone_value(work_val),
                })
            }
            continue
        }

        work_sub, work_is_obj := work_val.(json.Object)
        base_sub, base_is_obj := base_val.(json.Object)
        if work_is_obj && base_is_obj {
            _json_diff_objects(base_sub, work_sub, full_path, target, out)
            continue
        }

        if !_json_values_equal(base_val, work_val) {
            append(out, Override{
                target        = target,
                property_path = strings.clone(full_path),
                value         = json.clone_value(work_val),
            })
        }
    }
}

nested_scene_diff_overrides :: proc(base_raw: []byte, work_raw: []byte, prefab_guid: Asset_GUID = {}) -> [dynamic]Override {
	out := make([dynamic]Override)

	base_copy := make([]byte, len(base_raw))
	defer delete(base_copy)
	copy(base_copy, base_raw)
	work_copy := make([]byte, len(work_raw))
	defer delete(work_copy)
	copy(work_copy, work_raw)

	base_val: json.Value
	work_val: json.Value
	if json.unmarshal_string(string(base_copy), &base_val) != nil do return out
	if json.unmarshal_string(string(work_copy), &work_val) != nil {
		json.destroy_value(base_val)
		return out
	}
    defer json.destroy_value(base_val)
    defer json.destroy_value(work_val)

    base_root, base_ok := base_val.(json.Object)
    work_root, work_ok := work_val.(json.Object)
    if !base_ok || !work_ok do return out

    get_array :: proc(obj: json.Object, key: string) -> json.Array {
        v, ok := obj[key]
        if !ok do return nil
        arr, _ := v.(json.Array)
        return arr
    }

    array_keys := []string{"transforms", "cameras", "lifetimes", "players", "scripts", "sprite_renderers"}
    for section_key in array_keys {
        base_arr := get_array(base_root, section_key)
        work_arr := get_array(work_root, section_key)
        if len(work_arr) == 0 do continue
        for work_item in work_arr {
            wo, ok := work_item.(json.Object)
            if !ok do continue
            tid, tid_ok := _json_local_id_of(wo)
            if !tid_ok do continue
            for base_item in base_arr {
                bo, bok := base_item.(json.Object)
                if !bok do continue
                bid, bid_ok := _json_local_id_of(bo)
                if !bid_ok || bid != tid do continue
                _json_diff_objects(bo, wo, "", PPtr{guid = prefab_guid, local_id = tid}, &out)
                break
            }
        }
    }

    return out
}

NestedScene :: struct {
    local_id:             Local_ID,
    // For native NSs this equals `local_id`. For inner NSs this is the NS's
    // file-stable lid in its parent prefab file (before any host-scene remap).
    // Used as the projection key for Unity-style XOR-encoded deep-target
    // disambiguation: same-prefab-instantiated-twice yields different
    // local_id_in_parent values across the two outer-prefab PrefabInstances,
    // so projecting a deep object's lid through them produces unique results.
    local_id_in_parent:   Local_ID,
    source_prefab:        Asset_GUID,
    transform_parent:     Local_ID,
    host_breadcrumb_id:   Local_ID,
    sibling_index:        int,
    source_root_id:       Local_ID `json:"-"`,
    expand_parent:        Transform_Handle `json:"-"`,
    overrides:            [dynamic]Override,
}

transform_is_nested_owned :: proc(tH: Transform_Handle) -> bool {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(tH))
    if t == nil do return false
    return t.nested_owned
}

transform_find_nested_host :: proc(tH: Transform_Handle) -> Transform_Handle {
    w := ctx_world()
    current := tH
    for pool_valid(&w.transforms, Handle(current)) {
        t := pool_get(&w.transforms, Handle(current))
        if t == nil do return {}
        if !t.nested_owned {
            if scene_find_nested_scene_for_host(t.scene, current) != nil {
                return current
            }
        }
        current = Transform_Handle(t.parent.handle)
    }
    return {}
}

// Walks `tH` and its ancestors and returns the nearest one that is the host of
// some NestedScene record, regardless of `nested_owned`. Differs from
// `transform_find_nested_host` (which only stops at NON-nested-owned hosts and
// thus returns the outermost native host) — for a transform 2+ prefab levels
// deep in a nested chain, this returns its *own* enclosing inner-NS host, which
// is the record that owns overrides for that transform's content.
transform_immediate_nested_host :: proc(tH: Transform_Handle) -> Transform_Handle {
    w := ctx_world()
    current := tH
    for pool_valid(&w.transforms, Handle(current)) {
        t := pool_get(&w.transforms, Handle(current))
        if t == nil do return {}
        if scene_find_nested_scene_for_host(t.scene, current) != nil {
            return current
        }
        current = Transform_Handle(t.parent.handle)
    }
    return {}
}

transform_nested_enclosing_host :: proc(tH: Transform_Handle) -> Transform_Handle {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(tH))
    if t == nil do return {}
    if !t.nested_owned {
        if scene_find_nested_scene_for_host(t.scene, tH) != nil {
            return tH
        }
        return {}
    }
    current := Transform_Handle(t.parent.handle)
    for pool_valid(&w.transforms, Handle(current)) {
        ct := pool_get(&w.transforms, Handle(current))
        if ct == nil do return {}
        if !ct.nested_owned {
            if scene_find_nested_scene_for_host(ct.scene, current) != nil {
                return current
            }
            return {}
        }
        current = Transform_Handle(ct.parent.handle)
    }
    return {}
}

// Single pass over transform slots: returns (first matching handle, count).
// Replaces the previous _count + _first pair which scanned the same slots twice.
_nested_scene_find_outer_non_nested :: proc(s: ^Scene, id: Local_ID) -> (Transform_Handle, int) {
	if s == nil || id == 0 do return {}, 0
	w := ctx_world()
	first: Transform_Handle = {}
	n := 0
	for i in 0 ..< len(w.transforms.slots) {
		slot := &w.transforms.slots[i]
		if !slot.alive do continue
		tt := &slot.data
		if tt.scene != s || tt.local_id != id do continue
		if tt.nested_owned do continue
		if n == 0 {
			first = Transform_Handle(Handle{index = u32(i), generation = slot.generation, type_key = .Transform})
		}
		n += 1
	}
	return first, n
}

@(private = "file")
_transform_is_descendant_or_self :: proc(tH, ancestorH: Transform_Handle) -> bool {
	w := ctx_world()
	h := tH
	for _ in 0 ..< 4096 {
		if h == ancestorH do return true
		t := pool_get(&w.transforms, Handle(h))
		if t == nil do return false
		if t.parent.handle == {} do return false
		h = Transform_Handle(t.parent.handle)
	}
	return false
}

@(private = "file")
_nested_scene_scan_hosts_for_lid :: proc(s: ^Scene, ns: ^NestedScene, lid: Local_ID) -> (Transform_Handle, int) {
	if s == nil || ns == nil || lid == 0 do return {}, 0
	if ns.host_breadcrumb_id != 0 {
		bc, ok := breadcrumb_get(s, ns.host_breadcrumb_id)
		if !ok || bc.scene_instance != ns.local_id do return {}, 0
		if !pptr_guid_is_empty(bc.scene_source.guid) do return {}, 0
		if bc.scene_source.local_id != lid do return {}, 0
	}
	w := ctx_world()
	first: Transform_Handle = {}
	n := 0
	for i in 0 ..< len(w.transforms.slots) {
		slot := &w.transforms.slots[i]
		if !slot.alive do continue
		tt := &slot.data
		if tt.scene != s || tt.local_id != lid do continue
		tH := Transform_Handle(Handle{index = u32(i), generation = slot.generation, type_key = .Transform})
		if ns.expand_parent != {} {
			if !tt.nested_owned do continue
			if !_transform_is_descendant_or_self(tH, ns.expand_parent) do continue
		}
		if n == 0 do first = tH
		n += 1
	}
	return first, n
}

nested_row_direct_for_host :: proc(s: ^Scene, host_tH: Transform_Handle) -> ^NestedScene {
	ht := pool_get(&ctx_world().transforms, Handle(host_tH))
	if ht == nil || ht.scene != s || ht.nested_owned do return nil
	for &on in s.nested_scenes {
		if on.transform_parent == ht.local_id {
			return &on
		}
	}
	return nil
}

nested_scene_hosts_transform :: proc(s: ^Scene, ns: ^NestedScene, host_tH: Transform_Handle) -> bool {
	if s == nil do return false
	t := pool_get(&ctx_world().transforms, Handle(host_tH))
	if t == nil || t.scene != s do return false
	if ns.expand_parent != {} {
		if !_transform_is_descendant_or_self(host_tH, ns.expand_parent) {
			return false
		}
	}
	if ns.host_breadcrumb_id != 0 {
		bc, ok := breadcrumb_get(s, ns.host_breadcrumb_id)
		if !ok || bc.scene_instance != ns.local_id do return false
		if !pptr_guid_is_empty(bc.scene_source.guid) do return false
		lid := bc.scene_source.local_id

		if !t.nested_owned {
			if dir := nested_row_direct_for_host(s, host_tH); dir != nil {
				if ns.source_prefab != dir.source_prefab {
					return false
				}
			}
		}

		if t.nested_owned && t.local_id == lid {
			if ns.expand_parent != {} {
				// The descendant-or-self check at the top of this proc already
				// scoped host_tH to ns.expand_parent's subtree. Within that
				// subtree, the breadcrumb's scene_source.local_id uniquely
				// identifies the host transform (each inner NS in the parent
				// prefab has a distinct transform_parent). transform_find_nested_host
				// would walk past the immediate inner host all the way to the
				// outermost native host, which gave wrong answers for chains
				// 3+ levels deep — so don't use it here.
				return true
			}
			if dir := nested_row_direct_for_host(s, transform_find_nested_host(host_tH)); dir != nil {
				return ns.source_prefab != dir.source_prefab
			}
			return false
		}

		if h, ok2 := bimap_get(&s.local_ids, lid); ok2 {
			return h == Handle(host_tH)
		}
		want, n := _nested_scene_scan_hosts_for_lid(s, ns, lid)
		return n == 1 && want == host_tH
	}
	if ns.transform_parent != t.local_id do return false
	if h, ok2 := bimap_get(&s.local_ids, ns.transform_parent); ok2 {
		return h == Handle(host_tH)
	}
	want, n := _nested_scene_scan_hosts_for_lid(s, ns, ns.transform_parent)
	return n == 1 && want == host_tH
}

// On-disk / freshly-loaded marker for a variant's root NestedScene:
// transform_parent == 0 (no host transform in the file) and native
// (expand_parent == {}). At load this is rebound to a synthesized placeholder
// host so resolution/inspector/save treat it as an ordinary hosted NS; save
// writes transform_parent back to 0.
nested_scene_is_root :: proc(ns: ^NestedScene) -> bool {
	return ns != nil && ns.transform_parent == 0 && ns.expand_parent == {}
}

// Runtime marker for a loaded variant's root NS: a native NS (expand_parent
// == {}) whose host transform IS the scene root (the synthesized placeholder).
// Used by save to write transform_parent back to 0 and to avoid emitting the
// placeholder as a transform.
nested_scene_is_root_variant :: proc(s: ^Scene, ns: ^NestedScene) -> bool {
	if s == nil || ns == nil || ns.expand_parent != {} do return false
	if s.root.handle == {} do return false
	host := nested_scene_resolve_host_handle(s, ns)
	return host != {} && Handle(host) == s.root.handle
}

nested_scene_resolve_host_handle :: proc(s: ^Scene, ns: ^NestedScene) -> Transform_Handle {
	if s == nil || ns == nil do return {}

	lid := ns.transform_parent
	if ns.host_breadcrumb_id != 0 {
		bc, ok := breadcrumb_get(s, ns.host_breadcrumb_id)
		if !ok || bc.scene_instance != ns.local_id do return {}
		if !pptr_guid_is_empty(bc.scene_source.guid) do return {}
		lid = bc.scene_source.local_id
	}

	if ns.expand_parent != {} {
		first, n := _nested_scene_scan_hosts_for_lid(s, ns, lid)
		if n == 1 do return first
		return {}
	}

	if h, ok2 := bimap_get(&s.local_ids, lid); ok2 {
		cand := Transform_Handle(h)
		if nested_scene_hosts_transform(s, ns, cand) do return cand
	}
	first, n := _nested_scene_scan_hosts_for_lid(s, ns, lid)
	if n == 1 do return first
	return {}
}

nested_scene_attach_host_breadcrumb :: proc(s: ^Scene, ns: ^NestedScene, host_local_id: Local_ID) -> bool {
    if s == nil || ns == nil || host_local_id == 0 do return false
    peg := scene_next_id(s)
    if !scene_breadcrumb_put(
        s,
        Breadcrumb{
            local_id       = peg,
            scene_source   = PPtr{local_id = host_local_id, guid = Asset_GUID{}},
            scene_instance = ns.local_id,
        },
    ) {
        return false
    }
    ns.host_breadcrumb_id = peg
    return true
}

nested_scene_ensure_host_pegs :: proc(s: ^Scene) {
    if s == nil do return
    for &ns in s.nested_scenes {
        if ns.host_breadcrumb_id != 0 do continue
        if ns.transform_parent == 0 do continue
        nested_scene_attach_host_breadcrumb(s, &ns, ns.transform_parent)
    }
}

scene_find_nested_scene_for_host :: proc(s: ^Scene, host_tH: Transform_Handle) -> ^NestedScene {
	if s == nil do return nil
	w := ctx_world()
	t := pool_get(&w.transforms, Handle(host_tH))
	if t == nil || t.scene != s do return nil
	for &ns in s.nested_scenes {
		if nested_scene_hosts_transform(s, &ns, host_tH) do return &ns
	}
	return nil
}

// Returns the prefab's bytes with variant inheritance flattened: for a flat
// prefab, its raw bytes (owned=false, an alias of scene_lib); for a variant
// (a file whose nested_scenes hold a record with transform_parent == 0), the
// base resolved + the variant's own overrides baked in + the variant's added
// transforms merged — a normal flat scene file. Recurses for variant-of-variant.
// `owned` is true when the returned slice is freshly allocated (caller frees).
// The XOR projection key for an NS. The invariant (docs/NestedPrefabs.md) is
// local_id_in_parent == local_id for native NSs; some older files were authored
// with local_id_in_parent == 0 (invalid — lids start at 1), which breaks
// (un)projection. Fall back to local_id so deep-override lids round-trip.
_ns_projection_key :: proc(ns: ^NestedScene) -> Local_ID {
    if ns.local_id_in_parent != 0 do return ns.local_id_in_parent
    return ns.local_id
}

_prefab_resolved_bytes :: proc(guid: Asset_GUID, depth := 0) -> (out: []byte, owned: bool) {
    if depth > 32 do return nil, false
    raw, has := scene_lib[guid]
    if !has {
        if !scene_lib_register(guid) do return nil, false
        raw, has = scene_lib[guid]
        if !has do return nil, false
    }

    vf: SceneFile
    {
        cpy := make([]byte, len(raw), context.temp_allocator)
        copy(cpy, raw)
        if json.unmarshal(cpy, &vf) != nil do return nil, false
    }
    root_ns_idx := -1
    for ns, i in vf.nested_scenes {
        if ns.transform_parent == 0 {
            root_ns_idx = i
            break
        }
    }
    if root_ns_idx < 0 {
        scene_file_destroy(&vf)
        return raw, false   // flat prefab — raw bytes are already resolved
    }

    root_ns := vf.nested_scenes[root_ns_idx]

    // Resolve the base (recursively flatten if it too is a variant), then bake
    // this variant's overrides onto it.
    base_bytes, base_owned := _prefab_resolved_bytes(root_ns.source_prefab, depth + 1)
    if base_bytes == nil {
        scene_file_destroy(&vf)
        return nil, false
    }
    baked := nested_scene_apply_overrides(base_bytes, root_ns.overrides[:], root_ns.source_prefab)
    baked_owned := raw_data(baked) != raw_data(base_bytes)
    if base_owned && baked_owned do delete(base_bytes)

    base_sf: SceneFile
    {
        cpy := make([]byte, len(baked), context.temp_allocator)
        copy(cpy, baked)
        ok := json.unmarshal(cpy, &base_sf) == nil
        if baked_owned do delete(baked)
        else if base_owned do delete(base_bytes)
        if !ok {
            scene_file_destroy(&vf)
            return nil, false
        }
    }

    // Merge the variant's own additions (transforms + components + inner NSs)
    // into the base. Their parent lids already reference the base root lid
    // (== base_sf.root), so no rewrite is needed; transfer ownership and clear
    // vf's containers so scene_file_destroy(&vf) doesn't double-free. Also link
    // each addition into its parent's `children` list (the base file's parent
    // transform doesn't list the variant's additions), so the load materializes
    // them under the base rather than orphaning them.
    for t in vf.transforms {
        append(&base_sf.transforms, t)
        for &bt in base_sf.transforms {
            if bt.local_id == t.parent.pptr.local_id {
                append(&bt.children, Ref{ pptr = PPtr{local_id = t.local_id} })
                break
            }
        }
    }
    for c in vf.cameras          do append(&base_sf.cameras, c)
    for c in vf.lifetimes        do append(&base_sf.lifetimes, c)
    for c in vf.players          do append(&base_sf.players, c)
    for c in vf.scripts          do append(&base_sf.scripts, c)
    for c in vf.sprite_renderers do append(&base_sf.sprite_renderers, c)
    for ns, i in vf.nested_scenes {
        if i == root_ns_idx do continue
        append(&base_sf.nested_scenes, ns)
    }

    // DEEP overrides on the variant's root NS target content INSIDE the base's
    // own nested prefabs (target.guid != root_ns.source_prefab), so they weren't
    // baked by nested_scene_apply_overrides above (which only matches shallow
    // targets in the base's namespace). Carry each forward onto the matching
    // inner NS record, un-projecting the lid by that NS's local_id_in_parent, so
    // it applies when this flattened prefab is loaded and its inner NSs resolve.
    // (Matches the live-patch DFS, but persisted into the flattened bytes — this
    // is what makes a variant's deep override render when it is NESTED, not just
    // when opened top-level.)
    for ov in root_ns.overrides {
        if ov.target.guid == root_ns.source_prefab do continue   // shallow, already baked
        if asset_guid_is_empty(ov.target.guid) do continue
        // Push onto EVERY inner NS that could host the target (same guid),
        // un-projecting by each one's own projection key. Only the NS whose
        // subtree actually contains the un-projected lid applies it at resolve
        // time; the rest are harmless no-ops (no matching lid). Picking a single
        // candidate is unsafe — same-prefab-instantiated-twice means the first
        // guid match may be the wrong instance.
        for &inner in base_sf.nested_scenes {
            if inner.source_prefab != ov.target.guid do continue
            unprojected := local_id_unproject(_ns_projection_key(&inner), ov.target.local_id)
            append(&inner.overrides, Override{
                target        = PPtr{guid = ov.target.guid, local_id = unprojected},
                property_path = strings.clone(ov.property_path),
                value         = json.clone_value(ov.value),
            })
        }
    }

    for bc in vf.breadcrumbs do append(&base_sf.breadcrumbs, bc)
    if vf.next_local_id > base_sf.next_local_id do base_sf.next_local_id = vf.next_local_id
    // base_sf.root stays the base root lid. Detach moved containers from vf so
    // scene_file_destroy(&vf) below doesn't double-free their elements (the
    // root NS's overrides were consumed into the bake and are freed with vf).
    {
        // Free only the root NS overrides; the other NS records were moved.
        root_rec := &vf.nested_scenes[root_ns_idx]
        for &ov in root_rec.overrides {
            delete(ov.property_path)
            json.destroy_value(ov.value)
        }
        delete(root_rec.overrides)
    }
    delete(vf.transforms); vf.transforms = nil
    delete(vf.nested_scenes); vf.nested_scenes = nil
    delete(vf.breadcrumbs); vf.breadcrumbs = nil
    delete(vf.cameras); vf.cameras = nil
    delete(vf.lifetimes); vf.lifetimes = nil
    delete(vf.players); vf.players = nil
    delete(vf.scripts); vf.scripts = nil
    delete(vf.sprite_renderers); vf.sprite_renderers = nil

    opts := json.Marshal_Options{spec = .JSON, pretty = false}
    data, merr := json.marshal(base_sf, opts)
    scene_file_destroy(&base_sf)
    if merr != nil do return nil, false
    return data, true
}

// Guids currently being resolved up the active resolve stack. A prefab that
// (directly or via a variant chain) nests itself would otherwise recurse
// forever; we detect the repeat and skip it instead of crashing.
@(private = "file")
_resolve_guid_stack: [dynamic]Asset_GUID

nested_scene_resolve :: proc(host_tH: Transform_Handle) {
    w := ctx_world()
    host_t := pool_get(&w.transforms, Handle(host_tH))
    if host_t == nil do return

    _nested_scene_unresolve(host_tH)

    ns := scene_find_nested_scene_for_host(host_t.scene, host_tH)
    if ns == nil do return
    guid := ns.source_prefab
    empty_guid := Asset_GUID{}
    if guid == empty_guid do return

    // Cycle guard: if this prefab is already being resolved higher on the stack,
    // a nesting cycle exists (e.g. a prefab that nests its own variant). Skip it
    // — the host stays an unresolved nested-scene placeholder rather than
    // overflowing the stack.
    for g in _resolve_guid_stack {
        if g == guid {
            fmt.printf("[NestedScene] cycle detected resolving %v; skipping to avoid infinite nesting\n", guid)
            return
        }
    }
    append(&_resolve_guid_stack, guid)
    defer {
        pop(&_resolve_guid_stack)
        if len(_resolve_guid_stack) == 0 {
            delete(_resolve_guid_stack)
            _resolve_guid_stack = nil
        }
    }

    // The prefab bytes, with any variant inheritance resolved to a flat scene
    // file (base + the variant's own overrides + additions). For a flat prefab
    // this is just its raw bytes. This makes a variant nest exactly like any
    // other prefab — its own overrides are baked into this baked baseline, so
    // only the HOST scene's overrides remain editable (Unity's model).
    resolved, resolved_owned := _prefab_resolved_bytes(guid)
    if resolved == nil do return
    defer if resolved_owned do delete(resolved)

	baked := nested_scene_apply_overrides(resolved, ns.overrides[:], ns.source_prefab)
	baked_owned := len(ns.overrides) > 0 && raw_data(baked) != raw_data(resolved)
	defer if baked_owned do delete(baked)

    sf: SceneFile
    if err := json.unmarshal(baked, &sf); err != nil do return
    defer scene_file_destroy(&sf)

    host_scene := host_t.scene
    ns.source_root_id = sf.root

    nested_before := len(host_scene.nested_scenes)
    nested_root_tH := _scene_load_as_child(&sf, host_tH, host_scene, ns.source_prefab, true)

    for i in nested_before..<len(host_scene.nested_scenes) {
        if host_scene.nested_scenes[i].expand_parent == {} {
            host_scene.nested_scenes[i].expand_parent = host_tH
        }
    }

    if nested_root_tH == {} do return

    nested_root := pool_get(&w.transforms, Handle(nested_root_tH))
    if nested_root == nil do return

    host_t = pool_get(&w.transforms, Handle(host_tH))

    for i in 0..<len(host_t.children) {
        if host_t.children[i].handle == Handle(nested_root_tH) {
            ordered_remove(&host_t.children, i)
            break
        }
    }

    for &c in nested_root.components {
        if world_pool_valid(w, c.handle) {
            raw_c := world_pool_get(w, c.handle)
            if raw_c != nil {
                base := cast(^CompData)raw_c
                base.owner = host_tH
                base.nested_owned = true
            }
        }
        append(&host_t.components, c)
    }
    clear(&nested_root.components)

    for child in nested_root.children {
        ct := pool_get(&w.transforms, child.handle)
        if ct == nil do continue
        ct.parent = make_transform_ref(host_tH)
        append(&host_t.children, child)
        _mark_subtree_nested_owned(Transform_Handle(child.handle))
    }
    clear(&nested_root.children)

    transform_destroy(nested_root_tH)

    // Resolve nested scenes within the absorbed (now nested-owned) base content.
    host_t = pool_get(&w.transforms, Handle(host_tH))
    if host_t != nil {
        children_copy := make([]Ref, len(host_t.children), context.temp_allocator)
        copy(children_copy, host_t.children[:])
        for child in children_copy {
            ct := pool_get(&w.transforms, child.handle)
            if ct == nil do continue
            if ct.nested_owned {
                _scene_resolve_nested_in_subtree(Transform_Handle(child.handle))
            }
        }
    }

    // Apply deep overrides (those whose breadcrumb has a scene_path through
    // inner prefabs) by patching the live tree directly. Per docs/NestedPrefabs.md
    // overrides live at the root scene level only; inner NS records carry their
    // own prefab-baked overrides but never copies of root's. We locate each
    // deep target via reflection over the materialized subtree, then run
    // type_cleanup_by_typeid on the live field to free what's there before
    // unmarshaling the new JSON value into the same slot.
    //
    // Re-fetch `ns`: the recursive resolve above appends to s.nested_scenes,
    // which can reallocate the dynamic array and dangle the `ns` captured at the
    // top of this proc (EXC_BAD_ACCESS when iterating ns.overrides otherwise).
    ns = scene_find_nested_scene_for_host(host_scene, host_tH)
    if ns == nil do return
    _nested_scene_apply_deep_overrides_live(host_tH, ns)
}

_mark_subtree_nested_owned :: proc(root_tH: Transform_Handle) {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(root_tH))
    if t == nil do return
    t.nested_owned = true
    for &c in t.components {
        raw := world_pool_get(w, c.handle)
        if raw == nil do continue
        base := cast(^CompData)raw
        base.nested_owned = true
    }
    for child in t.children {
        _mark_subtree_nested_owned(Transform_Handle(child.handle))
    }
}

_nested_scene_unresolve :: proc(host_tH: Transform_Handle) {
    w := ctx_world()
    host_t := pool_get(&w.transforms, Handle(host_tH))
    if host_t == nil do return
    s := host_t.scene

    to_destroy_children := make([dynamic]Transform_Handle, 0, len(host_t.children), context.temp_allocator)
    for child in host_t.children {
        ct := pool_get(&w.transforms, child.handle)
        if ct == nil do continue
        if ct.nested_owned {
            append(&to_destroy_children, Transform_Handle(child.handle))
        }
    }
    for tH in to_destroy_children {
        transform_destroy(tH)
    }

    host_t = pool_get(&w.transforms, Handle(host_tH))
    if host_t == nil do return

    to_remove_comps := make([dynamic]Handle, 0, len(host_t.components), context.temp_allocator)
    for c in host_t.components {
        if !world_pool_valid(w, c.handle) do continue
        raw := world_pool_get(w, c.handle)
        if raw == nil do continue
        base := cast(^CompData)raw
        if base.nested_owned {
            append(&to_remove_comps, c.handle)
        }
    }
    for h in to_remove_comps {
        transform_remove_comp(host_tH, h)
    }

    // Drop inner NS records whose expand_parent was in the subtree we just
    // destroyed. Without this, _scene_load_as_child will re-clone fresh inner
    // NS records (with new expand_parent values) on the next resolve, leaving
    // the old ones as zombies in s.nested_scenes — they'd shadow the fresh
    // ones in chain walks and break subsequent resolves.
    if s != nil {
        write := 0
        for i in 0 ..< len(s.nested_scenes) {
            ns := s.nested_scenes[i]
            // Native NS records (expand_parent == {}) are persistent metadata —
            // never drop them here.
            if ns.expand_parent == {} {
                s.nested_scenes[write] = ns
                write += 1
                continue
            }
            // Stale if the host transform it was anchored to no longer exists
            // (its subtree was destroyed above), OR if it was anchored directly
            // at `host_tH` — those inner records belong to THIS instance's
            // expansion, which we just tore down. host_tH itself stays valid on
            // a re-resolve (only its nested-owned children are destroyed), so
            // the `!ep_valid` check alone misses them, leaving stale records
            // that shadow the fresh clones in chain walks and corrupt sibling
            // instances of the same prefab.
            ep := ns.expand_parent
            ep_valid := pool_valid(&w.transforms, Handle(ep))
            if !ep_valid || ep == host_tH {
                breadcrumb_clear_for_nested_scene(s, ns.local_id)
                for &ov in ns.overrides {
                    delete(ov.property_path)
                    json.destroy_value(ov.value)
                }
                delete(ns.overrides)
                continue
            }
            s.nested_scenes[write] = ns
            write += 1
        }
        resize(&s.nested_scenes, write)
    }
}

_scene_resolve_nested_in_subtree :: proc(root_tH: Transform_Handle) {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(root_tH))
    if t == nil do return

    if scene_find_nested_scene_for_host(t.scene, root_tH) != nil {
        nested_scene_resolve(root_tH)
        return
    }

    children_copy := make([]Ref, len(t.children), context.temp_allocator)
    copy(children_copy, t.children[:])
    for child in children_copy {
        _scene_resolve_nested_in_subtree(Transform_Handle(child.handle))
    }
}

scene_resolve_all_nested :: proc(root_tH: Transform_Handle) {
    _scene_resolve_nested_in_subtree(root_tH)
}

nested_scene_has_override :: proc(ns: ^NestedScene, target: PPtr, property_path: string) -> bool {
    if ns == nil do return false
    for &ov in ns.overrides {
        if pptr_equals(ov.target, target) && ov.property_path == property_path do return true
    }
    return false
}

// Walks from `inner_host_tH` up the chain of expand_parent hosts to the root
// native NS, collecting (prefab_guid, transform_parent) hops along the way.
// Returns the root NS and the chain hops (top-down: chain[0] is the hop from
// the root NS into the next inner level; chain[last] is the hop into
// `inner_host_tH`'s NS). For native hosts (no chain) returns chain==nil.
//
// Like _nested_chain_to_root but collects each inner NS's
// local_id_in_parent (the projection key) instead of (transform_parent, guid).
// Top-down: chain[0] is the outermost inner NS's lid, chain[last] is the
// inner NS hosting `inner_host_tH`. Used to forward-project a target lid into
// the encoding stored in breadcrumbs (locate path) and to un-project it
// during resolution. Empty chain means inner_host_tH is native.
@(private = "file")
_nested_chain_to_root_lids :: proc(
    s: ^Scene,
    inner_host_tH: Transform_Handle,
    allocator := context.temp_allocator,
) -> (^NestedScene, [dynamic]Local_ID, bool) {
    if s == nil do return nil, nil, false
    inner_ns := scene_find_nested_scene_for_host(s, inner_host_tH)
    if inner_ns == nil do return nil, nil, false
    if inner_ns.expand_parent == {} {
        return inner_ns, nil, true
    }
    chain := make([dynamic]Local_ID, 0, 4, allocator)
    cur := inner_ns
    for _ in 0 ..< 64 {
        append(&chain, cur.local_id_in_parent)
        ep := cur.expand_parent
        if ep == {} do break
        outer := scene_find_nested_scene_for_host(s, ep)
        if outer == nil do return nil, chain, false
        if outer.expand_parent == {} {
            n := len(chain)
            for i in 0 ..< n / 2 {
                chain[i], chain[n - 1 - i] = chain[n - 1 - i], chain[i]
            }
            return outer, chain, true
        }
        cur = outer
    }
    return nil, chain, false
}

// Caller owns the returned dynamic array (allocated in `allocator`).
@(private = "file")
_nested_chain_to_root :: proc(
    s: ^Scene,
    inner_host_tH: Transform_Handle,
    allocator := context.temp_allocator,
) -> (^NestedScene, [dynamic]PPtr, bool) {
    if s == nil do return nil, nil, false
    inner_ns := scene_find_nested_scene_for_host(s, inner_host_tH)
    if inner_ns == nil do return nil, nil, false
    if inner_ns.expand_parent == {} {
        return inner_ns, nil, true
    }
    chain := make([dynamic]PPtr, 0, 4, allocator)
    cur := inner_ns
    for _ in 0 ..< 64 {
        append(&chain, PPtr{guid = cur.source_prefab, local_id = cur.transform_parent})
        ep := cur.expand_parent
        if ep == {} do break
        outer := scene_find_nested_scene_for_host(s, ep)
        if outer == nil do return nil, chain, false
        if outer.expand_parent == {} {
            // outer is native — reverse chain to top-down and return.
            n := len(chain)
            for i in 0 ..< n / 2 {
                chain[i], chain[n - 1 - i] = chain[n - 1 - i], chain[i]
            }
            return outer, chain, true
        }
        cur = outer
    }
    return nil, chain, false
}

// For a UI context where the user is inspecting a transform/component inside a
// nested-owned subtree, returns the root native NS and the (guid, projected lid)
// that root would hold as `Override.target` for `target_lid` in
// `inner_host_tH`'s prefab namespace. For native hosts the target is
// `(root_ns.source_prefab, target_lid)` — no projection needed. For deep hosts
// the target's guid names the leaf prefab and its lid is `target_lid` projected
// through every inner NS's `local_id_in_parent` on the way up. Caller compares
// the returned target against existing `ov.target` values via `pptr_equals`.
nested_scene_locate_root_override :: proc(
    s: ^Scene,
    inner_host_tH: Transform_Handle,
    target_lid: Local_ID,
) -> (^NestedScene, PPtr, bool) {
    if s == nil do return nil, {}, false
    root_ns, _, ok := _nested_chain_to_root(s, inner_host_tH)
    if !ok || root_ns == nil do return nil, {}, false

    leaf_ns := scene_find_nested_scene_for_host(s, inner_host_tH)
    if leaf_ns == nil do return nil, {}, false

    // Native host case: target lid is directly in the root NS prefab namespace.
    if leaf_ns.expand_parent == {} {
        return root_ns, PPtr{guid = root_ns.source_prefab, local_id = target_lid}, true
    }

    _, lid_chain, lok := _nested_chain_to_root_lids(s, inner_host_tH)
    if !lok do return nil, {}, false

    // Forward-project target_lid through the chain (top-down): for each NS
    // from root to leaf, XOR the running value by that NS's local_id_in_parent.
    projected := target_lid
    for i := len(lid_chain) - 1; i >= 0; i -= 1 {
        projected = local_id_project(lid_chain[i], projected)
    }

    return root_ns, PPtr{guid = leaf_ns.source_prefab, local_id = projected}, true
}

// Checks whether root scene has an override on (target_lid, property_path) for
// a transform/component that lives inside `inner_host_tH`'s nested subtree.
nested_scene_has_root_override :: proc(
    s: ^Scene,
    inner_host_tH: Transform_Handle,
    target_lid: Local_ID,
    property_path: string,
) -> bool {
    root_ns, target, ok := nested_scene_locate_root_override(s, inner_host_tH, target_lid)
    if !ok || root_ns == nil do return false
    return nested_scene_has_override(root_ns, target, property_path)
}

// Like nested_scene_has_root_override but returns true if the root NS has ANY
// override on `target_lid` regardless of property_path. Used for the "is any
// field on this transform/component overridden by root scene" check that
// drives component-header coloring.
nested_scene_has_any_root_override_for_target :: proc(
    s: ^Scene,
    inner_host_tH: Transform_Handle,
    target_lid: Local_ID,
) -> bool {
    root_ns, target, ok := nested_scene_locate_root_override(s, inner_host_tH, target_lid)
    if !ok || root_ns == nil do return false
    for &ov in root_ns.overrides {
        if pptr_equals(ov.target, target) do return true
    }
    return false
}

_nested_revert_field_ptr :: proc(ptr: rawptr, tid: typeid, path: string) -> (rawptr, typeid, bool) {
    dot := strings.index_byte(path, '.')
    key := path if dot < 0 else path[:dot]
    names := reflect.struct_field_names(tid)
    types := reflect.struct_field_types(tid)
    offsets := reflect.struct_field_offsets(tid)
    for i in 0..<len(names) {
        if names[i] != key do continue
        field_ptr := rawptr(uintptr(ptr) + offsets[i])
        if dot < 0 do return field_ptr, types[i].id, true
        return _nested_revert_field_ptr(field_ptr, types[i].id, path[dot+1:])
    }
    return nil, nil, false
}

// Walks the nested-owned subtree under `host_tH` (and the host itself), looking
// for a transform or component whose `local_id == target_id`. Returns a pointer
// into the live data for the property at `property_path`. Scoping the search
// to one host's subtree is what makes this safe when multiple instances of the
// same prefab share local_ids — picking by local_id alone would otherwise hit
// a sibling instance.
@(private = "file")
_nested_find_revert_target :: proc(
    host_tH: Transform_Handle,
    target_id: Local_ID,
    property_path: string,
    is_root_target: bool,
    revert_field_ptr: rawptr,
) -> (rawptr, typeid, bool) {
    if host_tH == {} do return nil, nil, false
    w := ctx_world()

    walk :: proc(
        w: ^World,
        tH: Transform_Handle,
        target_id: Local_ID,
        property_path: string,
        is_root_target: bool,
        is_host: bool,
        revert_field_ptr: rawptr,
    ) -> (rawptr, typeid, bool) {
        t := pool_get(&w.transforms, Handle(tH))
        if t == nil do return nil, nil, false

        match_self := false
        if is_host {
            if is_root_target do match_self = true
        } else if t.nested_owned && t.local_id == target_id {
            match_self = true
        }

        if match_self {
            if fp, ftid, ok := _nested_revert_field_ptr(t, Transform, property_path); ok {
                if revert_field_ptr == nil || uintptr(revert_field_ptr) == uintptr(fp) {
                    return fp, ftid, true
                }
            }
            for c in t.components {
                if c.handle.type_key == INVALID_TYPE_KEY do continue
                comp_ptr := world_pool_get(w, c.handle)
                if comp_ptr == nil do continue
                base := cast(^CompData)comp_ptr
                if !base.nested_owned do continue
                comp_tid := get_typeid_by_type_key(c.handle.type_key)
                if comp_tid == nil do continue
                if fp, ftid, ok := _nested_revert_field_ptr(comp_ptr, comp_tid, property_path); ok {
                    if revert_field_ptr == nil || uintptr(revert_field_ptr) == uintptr(fp) {
                        return fp, ftid, true
                    }
                }
            }
        } else if !is_host && t.nested_owned {
            for c in t.components {
                if c.handle.type_key == INVALID_TYPE_KEY do continue
                comp_ptr := world_pool_get(w, c.handle)
                if comp_ptr == nil do continue
                base := cast(^CompData)comp_ptr
                if !base.nested_owned do continue
                if base.local_id != target_id do continue
                comp_tid := get_typeid_by_type_key(c.handle.type_key)
                if comp_tid == nil do continue
                if fp, ftid, ok := _nested_revert_field_ptr(comp_ptr, comp_tid, property_path); ok {
                    if revert_field_ptr == nil || uintptr(revert_field_ptr) == uintptr(fp) {
                        return fp, ftid, true
                    }
                }
            }
        }

        for child in t.children {
            ct := pool_get(&w.transforms, child.handle)
            if ct == nil do continue
            if !ct.nested_owned do continue
            cth := Transform_Handle(child.handle)
            if fp, ftid, ok := walk(w, cth, target_id, property_path, is_root_target, false, revert_field_ptr); ok {
                return fp, ftid, true
            }
        }

        if is_host {
            for c in t.components {
                if c.handle.type_key == INVALID_TYPE_KEY do continue
                comp_ptr := world_pool_get(w, c.handle)
                if comp_ptr == nil do continue
                base := cast(^CompData)comp_ptr
                if !base.nested_owned do continue
                if base.local_id != target_id do continue
                comp_tid := get_typeid_by_type_key(c.handle.type_key)
                if comp_tid == nil do continue
                if fp, ftid, ok := _nested_revert_field_ptr(comp_ptr, comp_tid, property_path); ok {
                    if revert_field_ptr == nil || uintptr(revert_field_ptr) == uintptr(fp) {
                        return fp, ftid, true
                    }
                }
            }
        }

        return nil, nil, false
    }

    return walk(w, host_tH, target_id, property_path, is_root_target, true, revert_field_ptr)
}

// Locates the leaf NS host for an Override.target (a PPtr carrying
// (deepest_prefab_guid, projected_lid)) plus the un-projected lid within that
// leaf's prefab namespace. DFS through inner NSs descending from native_host,
// un-projecting target.local_id by each visited NS's local_id_in_parent. At a
// candidate whose source_prefab matches target.guid, verify by checking the
// candidate's resolved subtree contains the un-projected lid. Returns
// ({}, nil, 0) if not found.
@(private = "file")
_nested_walk_override_target :: proc(
    s: ^Scene,
    native_host_tH: Transform_Handle,
    target: PPtr,
) -> (Transform_Handle, ^NestedScene, Local_ID) {
    if s == nil do return {}, nil, 0
    if pptr_guid_is_empty(target.guid) do return {}, nil, 0

    // Single-level: target lives directly inside native_host's expansion.
    // No projection chain — the lid is already in target.guid's namespace.
    native_ns := scene_find_nested_scene_for_host(s, native_host_tH)
    if native_ns != nil && native_ns.source_prefab == target.guid {
        return native_host_tH, native_ns, target.local_id
    }

    // Multi-level: descend, un-projecting at each NS level.
    return _find_descendant_ns_by_projection(s, native_host_tH, target.guid, target.local_id)
}

// DFS through inner NSs descending from start_host_tH, looking for one whose
// source_prefab matches target_guid where the un-projected lid resolves to a
// real entity in the candidate's subtree. At each NS level the projected value
// is XORed by that NS's local_id_in_parent to peel off one level.
@(private = "file")
_find_descendant_ns_by_projection :: proc(
    s: ^Scene,
    start_host_tH: Transform_Handle,
    target_guid: Asset_GUID,
    projected: Local_ID,
) -> (Transform_Handle, ^NestedScene, Local_ID) {
    for &cand in s.nested_scenes {
        if cand.expand_parent != start_host_tH do continue
        cand_host := nested_scene_resolve_host_handle(s, &cand)
        if cand_host == {} do continue

        // Un-project one level using this candidate's projection key.
        next_projected := local_id_unproject(_ns_projection_key(&cand), projected)

        if cand.source_prefab == target_guid {
            // Verify next_projected resolves in this candidate's subtree.
            is_root := next_projected == cand.source_root_id
            h := _find_subtree_handle_by_lid(cand_host, next_projected, is_root)
            if h != {} {
                return cand_host, &cand, next_projected
            }
            // Wrong branch: continue searching.
        }
        if h, n, lid := _find_descendant_ns_by_projection(s, cand_host, target_guid, next_projected); n != nil {
            return h, n, lid
        }
    }
    return {}, nil, 0
}

@(private = "file")
ChainHop :: struct { guid: Asset_GUID, transform_parent: Local_ID, lid_in_parent: Local_ID }

// Builds the hop chain from `start_host_tH` down to (and including) the first
// inner NS whose source_prefab == target_guid. Each hop entry carries:
// (next_prefab_guid, host_transform_lid_in_outer_prefab_namespace,
//  next_NS's local_id_in_parent). Top-down. The lid_in_parent values are the
// XOR projection keys used to un-project deep target lids.
// Returns false if not found.
@(private = "file")
_collect_chain_to_prefab :: proc(s: ^Scene, start_host_tH: Transform_Handle, target_guid: Asset_GUID, out: ^[dynamic]ChainHop) -> bool {
    for &cand in s.nested_scenes {
        if cand.expand_parent != start_host_tH do continue
        cand_host := nested_scene_resolve_host_handle(s, &cand)
        if cand_host == {} do continue
        append(out, ChainHop{guid = cand.source_prefab, transform_parent = cand.transform_parent, lid_in_parent = cand.local_id_in_parent})
        if cand.source_prefab == target_guid do return true
        if _collect_chain_to_prefab(s, cand_host, target_guid, out) do return true
        // Backtrack — wrong branch.
        if len(out^) > 0 do pop(out)
    }
    return false
}

// Resolves a breadcrumb to the real runtime Handle of its target. For deep
// breadcrumbs (scene_path non-empty) walks the chain to find the leaf NS host
// then locates the target by prefab-namespaced lid in the host's nested-owned
// subtree. For depth-1 (path empty) the leaf is the native NS host itself.
// Returns {} when any step fails (chain stale, NS not yet materialized, target
// not found). Used by load-time resolution to migrate breadcrumb bimap
// entries from synthetic placeholders to the real target handle.
nested_resolve_breadcrumb_to_handle :: proc(s: ^Scene, bc: Breadcrumb) -> Handle {
    if s == nil do return {}
    // Find the native NS this breadcrumb is anchored to.
    native_ns: ^NestedScene = nil
    for &ns in s.nested_scenes {
        if ns.expand_parent != {} do continue
        if ns.local_id == bc.scene_instance {
            native_ns = &ns
            break
        }
    }
    if native_ns == nil do return {}

    native_host := nested_scene_resolve_host_handle(s, native_ns)
    if native_host == {} do return {}

    // Determine if target is in the native NS's own prefab (depth-1) or
    // deeper. If scene_source.guid matches native_ns.source_prefab, depth-1.
    leaf_host: Transform_Handle
    leaf_ns: ^NestedScene
    leaf_lid: Local_ID
    if pptr_guid_is_empty(bc.scene_source.guid) || bc.scene_source.guid == native_ns.source_prefab {
        leaf_host = native_host
        leaf_ns = native_ns
        leaf_lid = bc.scene_source.local_id
    } else {
        leaf_host, leaf_ns, leaf_lid = _nested_walk_override_target(s, native_host, bc.scene_source)
        if leaf_host == {} || leaf_ns == nil do return {}
    }

    is_root_target := leaf_lid == leaf_ns.source_root_id
    return _find_subtree_handle_by_lid(leaf_host, leaf_lid, is_root_target)
}

// Walks the nested-owned subtree rooted at `host_tH` looking for a transform
// or component whose prefab-namespaced local_id == target_lid.
// is_root_target == true means the target is the host transform itself.
@(private = "file")
_find_subtree_handle_by_lid :: proc(host_tH: Transform_Handle, target_lid: Local_ID, is_root_target: bool) -> Handle {
    if host_tH == {} do return {}
    w := ctx_world()

    walk :: proc(w: ^World, tH: Transform_Handle, target_lid: Local_ID, is_host_match: bool) -> Handle {
        t := pool_get(&w.transforms, Handle(tH))
        if t == nil do return {}
        if is_host_match do return Handle(tH)
        if t.nested_owned && t.local_id == target_lid do return Handle(tH)
        if t.nested_owned {
            for c in t.components {
                if c.handle.type_key == INVALID_TYPE_KEY do continue
                raw := world_pool_get(w, c.handle)
                if raw == nil do continue
                base := cast(^CompData)raw
                if !base.nested_owned do continue
                if base.local_id == target_lid do return c.handle
            }
        }
        for child in t.children {
            ct := pool_get(&w.transforms, child.handle)
            if ct == nil || !ct.nested_owned do continue
            if h := walk(w, Transform_Handle(child.handle), target_lid, false); h != {} {
                return h
            }
        }
        return {}
    }

    if is_root_target {
        return walk(w, host_tH, target_lid, true)
    }
    // Host's own components share the prefab namespace — check first.
    if t := pool_get(&w.transforms, Handle(host_tH)); t != nil {
        for c in t.components {
            if c.handle.type_key == INVALID_TYPE_KEY do continue
            raw := world_pool_get(w, c.handle)
            if raw == nil do continue
            base := cast(^CompData)raw
            if !base.nested_owned do continue
            if base.local_id == target_lid do return c.handle
        }
    }
    return walk(w, host_tH, target_lid, false)
}

// Patches the live field at `(target_id, property_path)` inside `host_tH`'s
// subtree using `value` JSON. `cleanup_T` (registered as `type_cleanup_by_typeid`)
// is contracted to free + zero the field, so unmarshal_any sees a valid empty
// slot. Returns true on success. Logs and returns false when the locate fails
// or the field type has no registered pointer typeid.
@(private = "file")
_nested_patch_live_field :: proc(
    host_tH: Transform_Handle,
    target_id: Local_ID,
    property_path: string,
    is_root_target: bool,
    value: json.Value,
) -> bool {
    live_ptr, live_tid, found := _nested_find_revert_target(host_tH, target_id, property_path, is_root_target, nil)
    if !found || live_ptr == nil do return false

    field_bytes, merr := json.marshal(value, {spec = .JSON}, context.temp_allocator)
    if merr != nil do return false

    type_cleanup_by_typeid(live_tid, live_ptr)
    ptr_tid, ptr_ok := get_pointer_typeid_by_typeid(live_tid)
    if !ptr_ok do return false
    if uerr := json.unmarshal_any(field_bytes, any{&live_ptr, ptr_tid}); uerr != nil do return false
    return true
}

// Iterates root NS's `overrides`, applies the deep ones (target.guid points to
// some prefab deeper than ns.source_prefab) by patching the live tree. Shallow
// overrides (target.guid == ns.source_prefab) were already folded in by
// `nested_scene_apply_overrides` during bake.
// Package-visible entry for the variant-root load path (scene_manager): the
// materialized variant root never goes through nested_scene_resolve, so its
// deep overrides must be applied explicitly after its subtree resolves.
nested_scene_apply_deep_overrides_live :: proc(host_tH: Transform_Handle, ns: ^NestedScene) {
    _nested_scene_apply_deep_overrides_live(host_tH, ns)
}

@(private = "file")
_nested_scene_apply_deep_overrides_live :: proc(host_tH: Transform_Handle, ns: ^NestedScene) {
    if ns == nil do return
    w := ctx_world()
    host_t := pool_get(&w.transforms, Handle(host_tH))
    if host_t == nil do return
    s := host_t.scene
    if s == nil do return

    for &ov in ns.overrides {
        if pptr_guid_is_empty(ov.target.guid) do continue
        if ov.target.guid == ns.source_prefab do continue

        // Deep: descend from native_host, un-projecting through each inner NS
        // by its local_id_in_parent.
        leaf_host, leaf_ns, leaf_lid := _nested_walk_override_target(s, host_tH, ov.target)
        if leaf_host == {} || leaf_ns == nil do continue
        is_root_target := leaf_lid == leaf_ns.source_root_id
        _nested_patch_live_field(leaf_host, leaf_lid, ov.property_path, is_root_target, ov.value)
    }
}

// The revert baseline: the value of `property_path` at row `leaf_lid` in
// `leaf_ns`'s chain-baked base — the leaf prefab with EVERY ancestor prefab's
// NS-for-child overrides applied and all variant inheritance flattened, but
// WITHOUT the open scene's own overrides (those live on the scene, not the
// prefab files). This is exactly the value the field reverts to, for shallow
// AND deep. Reuses `chain_baked_base_for_ns` (the same baseline the override
// CAPTURE diffs against), so capture and revert agree.
@(private = "file")
_nested_resolved_field_json :: proc(s: ^Scene, leaf_ns: ^NestedScene, leaf_lid: Local_ID, property_path: string) -> (json.Value, bool) {
    raw, ok := chain_baked_base_for_ns(s, leaf_ns)
    if !ok do return nil, false
    defer delete(raw)

    cpy := make([]byte, len(raw), context.temp_allocator)
    copy(cpy, raw)
    root_val: json.Value
    if json.unmarshal_string(string(cpy), &root_val) != nil do return nil, false
    defer json.destroy_value(root_val)
    root_obj, is_obj := root_val.(json.Object)
    if !is_obj do return nil, false

    for _, section_val in root_obj {
        arr, is_arr := section_val.(json.Array)
        if !is_arr do continue
        for item in arr {
            obj, ok := item.(json.Object)
            if !ok do continue
            lid, lid_ok := _json_local_id_of(obj)
            if !lid_ok || lid != leaf_lid do continue
            field_val, fok := _json_get_path(obj, property_path)
            if !fok do return nil, false
            return json.clone_value(field_val), true
        }
    }
    return nil, false
}

nested_scene_revert_override :: proc(
    s: ^Scene,
    ns: ^NestedScene,
    target: PPtr,
    property_path: string,
    revert_field_ptr: rawptr = nil,
) {
    if s == nil || ns == nil do return

    has_match := false
    for &ov in ns.overrides {
        if pptr_equals(ov.target, target) && ov.property_path == property_path {
            has_match = true
            break
        }
    }
    if !has_match do return

    // Locate the live field AND the leaf prefab the field lives in. The same
    // walk used by deep-override APPLY recovers the leaf NS + leaf-prefab lid;
    // reuse it so revert and apply agree on the target. For a shallow override
    // the leaf prefab is ns.source_prefab and the lid is target.local_id.
    native_host_tH := nested_scene_resolve_host_handle(s, ns)
    leaf_host_tH := native_host_tH
    leaf_target := target.local_id
    leaf_ns := ns
    leaf_root_id := ns.source_root_id

    is_deep := !pptr_guid_is_empty(target.guid) && target.guid != ns.source_prefab
    if is_deep {
        lh, lns, lid := _nested_walk_override_target(s, native_host_tH, target)
        if lh != {} && lns != nil {
            leaf_host_tH = lh
            leaf_target = lid
            leaf_ns = lns
            leaf_root_id = lns.source_root_id
        }
    }
    is_root_target := leaf_target == leaf_root_id

    live_ptr, live_tid, found := _nested_find_revert_target(
        leaf_host_tH,
        leaf_target,
        property_path,
        is_root_target,
        revert_field_ptr,
    )

    if found && live_ptr != nil {
        // Baseline = the field in leaf_ns's chain-baked base (every ancestor
        // prefab's overrides applied, variants flattened, but NOT the open
        // scene's own overrides). Same baseline the capture diffs against, for
        // both shallow and deep.
        baseline, ok := _nested_resolved_field_json(s, leaf_ns, leaf_target, property_path)
        if ok {
            defer json.destroy_value(baseline)
            field_bytes, merr := json.marshal(baseline, {spec = .JSON}, context.temp_allocator)
            if merr == nil {
                type_cleanup_by_typeid(live_tid, live_ptr)
                if ptr_tid, ptr_ok := get_pointer_typeid_by_typeid(live_tid); ptr_ok {
                    json.unmarshal_any(field_bytes, any{&live_ptr, ptr_tid})
                }
            }
        }
    }

    // Remove ALL matching entries. Duplicate (target, property_path) records
    // can only exist from stale data; leaving any behind would keep the field
    // visually flagged as overridden and require another revert click.
    write := 0
    for i in 0..<len(ns.overrides) {
        ov := ns.overrides[i]
        if pptr_equals(ov.target, target) && ov.property_path == property_path {
            delete(ov.property_path)
            json.destroy_value(ov.value)
            continue
        }
        ns.overrides[write] = ov
        write += 1
    }
    resize(&ns.overrides, write)
}

// Apply override (mirror of revert). Instead of dropping the override and
// resetting the live field, bake the override's value UP into the immediate-
// parent prefab file so it becomes the new baseline for every instance, then
// remove the override from the root NS.
//
//   - SHALLOW (target.guid == ns.source_prefab): the parent prefab is
//     ns.source_prefab itself; the value is patched directly onto that prefab's
//     own transform/component row.
//   - DEEP (root -> A -> B, override targets B): the parent prefab is A (one
//     level up from the leaf). The value is written as an override record in
//     A's NS-for-B, with the target lid un-projected exactly ONE level (so A's
//     record carries the leaf lid projected through only the last hop).
//
// `levels_up` (1-based from the leaf) selects which ancestor prefab to bake
// into: 1 = the prefab directly hosting the leaf, up to
// `nested_scene_apply_levels(...)` = `ns.source_prefab`.
//
// Because override precedence is *shallower-wins* (the root scene's deep
// override is applied last, on top of every inner-prefab bake), simply writing
// the value into the target prefab is not enough — any same-field override at a
// level SHALLOWER than the target would shadow it. So Apply also clears the
// same `(leaf-guid, property_path)` override from every intermediate prefab
// file between the target and the root, and from the root scene's NS.
//
// Returns false (leaving everything untouched) if the override doesn't exist,
// the chain can't be resolved, or the target file write fails — never drops
// user data on failure. On success the live field is left as-is: propagation
// re-resolves the subtree and the value is identical.
nested_scene_apply_override :: proc(
    s: ^Scene,
    ns: ^NestedScene,
    target: PPtr,
    property_path: string,
    levels_up: int = 1,
) -> bool {
    if s == nil || ns == nil do return false
    if levels_up < 1 do return false

    // Capture the value (clone) before any mutation.
    value: json.Value
    has_match := false
    for &ov in ns.overrides {
        if pptr_equals(ov.target, target) && ov.property_path == property_path {
            value = json.clone_value(ov.value, context.temp_allocator)
            has_match = true
            break
        }
    }
    if !has_match do return false

    // Resolve the target. Resolve the intermediate-clear targets too BEFORE any
    // mutation, because re-resolution (triggered by propagation later) would
    // invalidate `ns` and the live chain `_apply_resolve_parent` walks.
    parent_guid, is_direct, parent_lid, rec_child, tgt_guid, rec_tparent, ok := _apply_resolve_parent(s, ns, target, levels_up)
    if !ok do return false

    // Clear the same field from every level SHALLOWER than the chosen target
    // (higher level number = closer to the root scene), since shallower-wins
    // precedence would otherwise shadow what we just applied. Each shallower
    // level is an ancestor override record (never the lvl-1 owner bake), so we
    // skip any is_direct result. The root scene NS itself is cleared below.
    levels := nested_scene_apply_levels(s, ns, target)
    Clear :: struct { guid: Asset_GUID, lid: Local_ID, rec_child: Asset_GUID, tgt: Asset_GUID, rec_tparent: Local_ID }
    clears := make([dynamic]Clear, 0, levels, context.temp_allocator)
    for j := levels_up + 1; j <= levels; j += 1 {
        ig, idir, ilid, irec_child, itgt, irec, iok := _apply_resolve_parent(s, ns, target, j)
        if !iok || idir do continue
        append(&clears, Clear{ig, ilid, irec_child, itgt, irec})
    }

    // Track every prefab file touched so we propagate each exactly once, AFTER
    // all files and the in-memory root override are updated.
    touched := make([dynamic]Asset_GUID, 0, levels_up + 1, context.temp_allocator)
    add_touched :: proc(t: ^[dynamic]Asset_GUID, g: Asset_GUID) {
        for x in t do if x == g do return
        append(t, g)
    }

    // Write the target file (scene_lib refreshed, not yet propagated).
    if !_apply_patch_prefab(parent_guid, value, property_path, is_direct, parent_lid, rec_child, tgt_guid, rec_tparent, .Merge) {
        return false
    }
    add_touched(&touched, parent_guid)

    // Clear the same field from every shallower prefab level so the freshly
    // baked value isn't shadowed (precedence is shallower-wins).
    for c in clears {
        if _apply_patch_prefab(c.guid, nil, property_path, false, c.lid, c.rec_child, c.tgt, c.rec_tparent, .Remove) {
            add_touched(&touched, c.guid)
        }
    }

    // Remove ALL matching entries from the root NS (same shape as revert) —
    // BEFORE propagation, so re-resolve doesn't re-distribute the stale value.
    write := 0
    for i in 0..<len(ns.overrides) {
        ov := ns.overrides[i]
        if pptr_equals(ov.target, target) && ov.property_path == property_path {
            delete(ov.property_path)
            json.destroy_value(ov.value)
            continue
        }
        ns.overrides[write] = ov
        write += 1
    }
    resize(&ns.overrides, write)

    // Single propagation pass per touched prefab, now that the world is fully
    // updated. NOTE: this re-resolves and may reallocate `s.nested_scenes`, so
    // `ns` must not be used after this point.
    for g in touched {
        prefab_propagate(g)
    }
    return true
}

// Determines which prefab file an Apply writes into and in what shape.
// Level model (1-based, deepest -> shallowest):
//   lvl 1            = the field's OWNER prefab (`target.guid` for deep, or
//                      `ns.source_prefab` for shallow). Applied as a DIRECT
//                      field patch (the value is baked into that prefab; it
//                      stops being an override). "Apply to Scene <owner>".
//   lvl 2 .. levels  = each ancestor prefab between the owner and the open
//                      scene's direct prefab (`ns.source_prefab`). Applied as
//                      an override RECORD in that ancestor. "Apply as Override
//                      in <ancestor>".
// For a SHALLOW override (`target.guid == ns.source_prefab`) the owner IS the
// open scene's direct prefab, so there is exactly one level (bake).
// For a DEEP override over hop chain `hops` (len n), levels = n + 1: lvl 1 bakes
// into the leaf (`hops[n-1].guid`), lvl 2 records into `hops[n-2]`'s host …
// lvl n+1 records into `ns.source_prefab`.
@(private = "file")
_apply_resolve_parent :: proc(
    s: ^Scene, ns: ^NestedScene, target: PPtr, levels_up: int,
) -> (parent_guid: Asset_GUID, is_direct: bool, parent_lid: Local_ID,
      rec_child_guid: Asset_GUID, tgt_guid: Asset_GUID, rec_tparent: Local_ID, ok: bool) {
    if levels_up < 1 do return {}, false, 0, {}, {}, 0, false

    is_deep := !pptr_guid_is_empty(target.guid) && target.guid != ns.source_prefab
    if !is_deep {
        // Shallow: only level 1 (bake into ns.source_prefab's own row).
        if levels_up != 1 do return {}, false, 0, {}, {}, 0, false
        return ns.source_prefab, true, target.local_id, {}, {}, 0, true
    }

    native_host := nested_scene_resolve_host_handle(s, ns)
    if native_host == {} do return {}, false, 0, {}, {}, 0, false

    hops := make([dynamic]ChainHop, 0, 4, context.temp_allocator)
    if !_collect_chain_to_prefab(s, native_host, target.guid, &hops) do return {}, false, 0, {}, {}, 0, false
    n := len(hops)
    if n == 0 do return {}, false, 0, {}, {}, 0, false
    if levels_up > n + 1 do return {}, false, 0, {}, {}, 0, false

    if levels_up == 1 {
        // Bake directly into the owner (leaf) prefab. The lid is the root lid
        // fully un-projected through every hop into the leaf's own namespace.
        plid := target.local_id
        for hop in hops {
            plid = local_id_unproject(hop.lid_in_parent, plid)
        }
        return target.guid, true, plid, {}, {}, 0, true
    }

    // levels_up in 2..n+1 → ancestor override. Map to the host-prefab index:
    // the ancestor stack is [hops[n-2], …, hops[0], ns.source_prefab]; the
    // override RECORD lives in the prefab one above the record's child. Define
    // a := levels_up-1 in 1..n (an "override depth" identical to the old model).
    a := levels_up - 1
    // File = stack[n-a]: ns.source_prefab when n-a == 0, else hops[n-a-1].
    file_idx := n - a
    file_guid := ns.source_prefab if file_idx == 0 else hops[file_idx - 1].guid
    // Record's child NS source_prefab = hops[n-a]; override target.guid stays leaf.
    child_hop := hops[n - a]

    // Un-project the root lid through the first n-a+1 hops (hops[0 .. n-a]).
    plid := target.local_id
    for i in 0..=(n - a) {
        plid = local_id_unproject(hops[i].lid_in_parent, plid)
    }

    return file_guid, false, plid, child_hop.guid, target.guid, child_hop.transform_parent, true
}

// Number of Apply targets for this override (the max valid `levels_up`).
// Level 1 = bake into the field's owner prefab; levels 2..N = override in each
// ancestor up to `ns.source_prefab`. Shallow override → 1 (owner is the open
// scene's direct prefab). Deep override over n hops → n + 1. 0 if unresolvable.
nested_scene_apply_levels :: proc(s: ^Scene, ns: ^NestedScene, target: PPtr) -> int {
    if s == nil || ns == nil do return 0
    is_deep := !pptr_guid_is_empty(target.guid) && target.guid != ns.source_prefab
    if !is_deep do return 1
    native_host := nested_scene_resolve_host_handle(s, ns)
    if native_host == {} do return 0
    hops := make([dynamic]ChainHop, 0, 4, context.temp_allocator)
    if !_collect_chain_to_prefab(s, native_host, target.guid, &hops) do return 0
    return len(hops) + 1
}

// Returns (guid, is_owner_bake) for the prefab targeted by `levels_up`
// (1 = owner bake, 2..N = ancestor override). Used by the editor to label the
// Apply menu items. ok=false if out of range or chain unresolved.
nested_scene_apply_target_guid :: proc(s: ^Scene, ns: ^NestedScene, target: PPtr, levels_up: int) -> (guid: Asset_GUID, is_owner: bool, ok: bool) {
    if s == nil || ns == nil || levels_up < 1 do return {}, false, false
    is_deep := !pptr_guid_is_empty(target.guid) && target.guid != ns.source_prefab
    if !is_deep {
        if levels_up != 1 do return {}, false, false
        return ns.source_prefab, true, true // shallow: owner == source_prefab, baked
    }
    native_host := nested_scene_resolve_host_handle(s, ns)
    if native_host == {} do return {}, false, false
    hops := make([dynamic]ChainHop, 0, 4, context.temp_allocator)
    if !_collect_chain_to_prefab(s, native_host, target.guid, &hops) do return {}, false, false
    n := len(hops)
    if levels_up > n + 1 do return {}, false, false
    if levels_up == 1 do return target.guid, true, true // owner (leaf) bake
    a := levels_up - 1 // ancestor override depth 1..n
    file_idx := n - a
    g := ns.source_prefab if file_idx == 0 else hops[file_idx - 1].guid
    return g, false, true
}

_ApplyMode :: enum { Merge, Remove }

// Loads parent_guid's prefab bytes, applies the JSON mutation (merge an
// override / patch a row, or remove a matching override), writes the file, and
// re-commits the caches via _prefab_bytes_committed. `value` is ignored in
// .Remove mode. Returns false on IO/parse failure or when the mutation matched
// nothing (target NS record / row absent, or no override to remove).
// `rec_child_guid` is the source_prefab of the NS record to find in the file
// (the file's direct child). `tgt_guid` is the override's target.guid (the leaf
// prefab the field lives in) — equal to rec_child_guid at levels_up==1, deeper
// otherwise.
@(private = "file")
_apply_patch_prefab :: proc(
    parent_guid: Asset_GUID, value: json.Value, property_path: string,
    is_direct: bool, parent_lid: Local_ID, rec_child_guid: Asset_GUID, tgt_guid: Asset_GUID, rec_tparent: Local_ID,
    mode: _ApplyMode,
) -> bool {
    raw, has := scene_lib[parent_guid]
    if !has {
        if !scene_lib_register(parent_guid) do return false
        raw, has = scene_lib[parent_guid]
        if !has do return false
    }

    raw_copy := make([]byte, len(raw))
    defer delete(raw_copy)
    copy(raw_copy, raw)
    root_val: json.Value
    if json.unmarshal_string(string(raw_copy), &root_val) != nil do return false
    defer json.destroy_value(root_val)
    root_obj, is_obj := root_val.(json.Object)
    if !is_obj do return false

    patched := false
    if is_direct {
        // Patch the row whose local_id == parent_lid in any section array.
        for _, section_val in root_obj {
            arr, is_arr := section_val.(json.Array)
            if !is_arr do continue
            for &item in arr {
                obj, oo := item.(json.Object)
                if !oo do continue
                lid, lid_ok := _json_local_id_of(obj)
                if !lid_ok || lid != parent_lid do continue
                _json_set_path(&obj, property_path, value)
                item = obj
                patched = true
                break
            }
            if patched do break
        }
    } else {
        // Merge into / remove from the file's NS-for-child override list.
        ns_section, has_ns := root_obj["nested_scenes"]
        if has_ns {
            ns_arr, is_arr := ns_section.(json.Array)
            if is_arr {
                for &ns_item in ns_arr {
                    ns_obj, no := ns_item.(json.Object)
                    if !no do continue
                    if !_json_ns_matches(ns_obj, rec_child_guid, rec_tparent) do continue
                    switch mode {
                    case .Merge:
                        _json_merge_override(&ns_obj, tgt_guid, parent_lid, property_path, value)
                        patched = true
                    case .Remove:
                        patched = _json_remove_override(&ns_obj, parent_lid, property_path)
                    }
                    ns_item = ns_obj
                    break
                }
            }
        }
    }
    if !patched do return false

    opts := json.Marshal_Options{spec = .JSON, pretty = true, use_spaces = true, spaces = 2}
    data, merr := json.marshal(root_obj, opts)
    if merr != nil do return false
    defer delete(data)

    path, path_ok := asset_db_get_path(uuid.Identifier(parent_guid))
    if !path_ok do return false
    if os.write_entire_file(path, data) != nil do return false

    // Refresh scene_lib bytes only; the caller propagates once after all files
    // and its own in-memory override state are updated (avoids re-resolving
    // against a half-applied world / re-distributing the not-yet-removed root
    // override).
    _prefab_bytes_refresh(parent_guid, data)
    return true
}

// True if an NS-record JSON object has source_prefab == guid && transform_parent == tparent.
@(private = "file")
_json_ns_matches :: proc(ns_obj: json.Object, guid: Asset_GUID, tparent: Local_ID) -> bool {
    sp, has_sp := ns_obj["source_prefab"]
    if !has_sp do return false
    sp_str, is_str := sp.(json.String)
    if !is_str do return false
    parsed, perr := uuid.read(sp_str)
    if perr != nil do return false
    if Asset_GUID(parsed) != guid do return false

    tp, has_tp := ns_obj["transform_parent"]
    if !has_tp do return false
    #partial switch n in tp {
    case json.Float:   return Local_ID(n) == tparent
    case json.Integer: return Local_ID(n) == tparent
    }
    return false
}

// Replaces or appends an override entry {target:{guid,local_id}, property_path,
// value} in an NS-record JSON object's `overrides` array.
@(private = "file")
_json_merge_override :: proc(
    ns_obj: ^json.Object, child_guid: Asset_GUID, target_lid: Local_ID,
    property_path: string, value: json.Value,
) {
    guid_str := uuid.to_string(uuid.Identifier(child_guid), context.temp_allocator)

    ov_section, has_ov := ns_obj["overrides"]
    ov_arr: json.Array
    if has_ov {
        if a, is_arr := ov_section.(json.Array); is_arr do ov_arr = a
    }

    // Replace existing matching entry.
    for &item in ov_arr {
        obj, oo := item.(json.Object)
        if !oo do continue
        pp, has_pp := obj["property_path"]
        pp_str, pp_ok := pp.(json.String)
        if !has_pp || !pp_ok || string(pp_str) != property_path do continue
        tgt, has_tgt := obj["target"]
        tgt_obj, to := tgt.(json.Object)
        if !has_tgt || !to do continue
        if tlid, tlid_ok := _json_local_id_of(tgt_obj); !tlid_ok || tlid != target_lid do continue
        if existing, ex := obj["value"]; ex do json.destroy_value(existing)
        obj["value"] = json.clone_value(value)
        item = obj
        ns_obj["overrides"] = ov_arr
        return
    }

    // Append a new entry.
    tgt_obj := make(json.Object)
    tgt_obj["local_id"] = json.Integer(target_lid)
    tgt_obj["guid"] = json.String(strings.clone(guid_str))
    new_ov := make(json.Object)
    new_ov["target"] = tgt_obj
    new_ov["property_path"] = json.String(strings.clone(property_path))
    new_ov["value"] = json.clone_value(value)
    append(&ov_arr, new_ov)
    ns_obj["overrides"] = ov_arr
}

// Removes every override entry matching (target_lid, property_path) from an
// NS-record JSON object's `overrides` array. Returns true if anything was
// removed. Used by Apply to clear shadowing overrides on shallower prefab
// levels so the freshly-baked deeper value isn't masked.
@(private = "file")
_json_remove_override :: proc(ns_obj: ^json.Object, target_lid: Local_ID, property_path: string) -> bool {
    ov_section, has_ov := ns_obj["overrides"]
    if !has_ov do return false
    ov_arr, is_arr := ov_section.(json.Array)
    if !is_arr do return false

    removed := false
    write := 0
    for item in ov_arr {
        keep := true
        if obj, oo := item.(json.Object); oo {
            pp, has_pp := obj["property_path"]
            pp_str, pp_ok := pp.(json.String)
            tgt, has_tgt := obj["target"]
            tgt_obj, to := tgt.(json.Object)
            if has_pp && pp_ok && string(pp_str) == property_path && has_tgt && to {
                if tlid, tlid_ok := _json_local_id_of(tgt_obj); tlid_ok && tlid == target_lid {
                    keep = false
                }
            }
        }
        if keep {
            ov_arr[write] = item
            write += 1
        } else {
            json.destroy_value(item)
            removed = true
        }
    }
    if removed {
        resize(&ov_arr, write)
        ns_obj["overrides"] = ov_arr
    }
    return removed
}

nested_scene_add :: proc(s: ^Scene, source_prefab: Asset_GUID, host_tH: Transform_Handle, sibling_index: int) -> ^NestedScene {
    if s == nil do return nil
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(host_tH))
    if t == nil do return nil
    ns := NestedScene{
        local_id         = scene_next_id(s),
        source_prefab    = source_prefab,
        transform_parent = t.local_id,
        sibling_index    = sibling_index,
    }
    append(&s.nested_scenes, ns)
    ns_ptr := &s.nested_scenes[len(s.nested_scenes) - 1]
    nested_scene_attach_host_breadcrumb(s, ns_ptr, t.local_id)
    return ns_ptr
}

// Strips nested-scene metadata from `host_tH`'s subtree, leaving plain
// transforms/components in place. Used for runtime instantiation: the
// override-baked content from `nested_scene_resolve` is kept, but the
// NestedScene records, breadcrumbs, and `nested_owned` flags are dropped so
// the spawned subtree behaves like a flat hierarchy with no editor bookkeeping.
nested_scene_unpack_subtree :: proc(host_tH: Transform_Handle) {
    w := ctx_world()
    ht := pool_get(&w.transforms, Handle(host_tH))
    if ht == nil do return
    s := ht.scene
    if s == nil do return

    // Clear nested-owned flags AND renumber transforms/components with fresh
    // scene-unique local_ids. The resolved subtree carries lids from multiple
    // prefab namespaces (e.g. bullet's "Transform" lid=2 alongside c.scene's
    // own lid=2), which is fine while they're nested-owned because they aren't
    // registered in s.local_ids — but scene_copy_subtree serializes them by
    // their `local_id` field, producing JSON with duplicate ids that break
    // _scene_file_remap_local_ids on every subsequent paste.
    renumber :: proc(w: ^World, tH: Transform_Handle, s: ^Scene) {
        t := pool_get(&w.transforms, Handle(tH))
        if t == nil do return
        t.nested_owned = false

        new_lid := scene_next_id(s)
        bimap_remove_by_val(&s.local_ids, Handle(tH))
        if pool_valid(&w.transforms, t.parent.handle) {
            pt := pool_get(&w.transforms, t.parent.handle)
            if pt != nil {
                for &child in pt.children {
                    if child.handle == Handle(tH) {
                        child.pptr.local_id = new_lid
                        break
                    }
                }
            }
        }
        for child in t.children {
            ct := pool_get(&w.transforms, child.handle)
            if ct == nil do continue
            if ct.parent.pptr.local_id == t.local_id {
                ct.parent.pptr.local_id = new_lid
            }
        }
        t.local_id = new_lid
        bimap_insert(&s.local_ids, new_lid, Handle(tH))

        for &c in t.components {
            if c.handle.type_key == INVALID_TYPE_KEY do continue
            if !world_pool_valid(w, c.handle) do continue
            raw := world_pool_get(w, c.handle)
            if raw == nil do continue
            base := cast(^CompData)raw
            base.nested_owned = false
            new_clid := scene_next_id(s)
            bimap_remove_by_val(&s.local_ids, c.handle)
            base.local_id = new_clid
            c.local_id = new_clid
            bimap_insert(&s.local_ids, new_clid, c.handle)
        }

        for child in t.children {
            renumber(w, Transform_Handle(child.handle), s)
        }
    }
    renumber(w, host_tH, s)

    is_in_subtree :: proc(w: ^World, tH, root: Transform_Handle) -> bool {
        cur := tH
        for cur != {} {
            if cur == root do return true
            ct := pool_get(&w.transforms, Handle(cur))
            if ct == nil do return false
            cur = Transform_Handle(ct.parent.handle)
        }
        return false
    }

    ns_lids := make([dynamic]Local_ID, 0, 8, context.temp_allocator)
    for &ns in s.nested_scenes {
        host := nested_scene_resolve_host_handle(s, &ns)
        if host == {} do continue
        if is_in_subtree(w, host, host_tH) {
            append(&ns_lids, ns.local_id)
        }
    }

    for ns_lid in ns_lids {
        breadcrumb_clear_for_nested_scene(s, ns_lid)
        for i in 0..<len(s.nested_scenes) {
            if s.nested_scenes[i].local_id != ns_lid do continue
            ns := &s.nested_scenes[i]
            for &ov in ns.overrides {
                delete(ov.property_path)
                json.destroy_value(ov.value)
            }
            delete(ns.overrides)
            ordered_remove(&s.nested_scenes, i)
            break
        }
    }
}

nested_scene_remove :: proc(s: ^Scene, host_tH: Transform_Handle) {
    if s == nil do return
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(host_tH))
    if t == nil do return
    for i in 0 ..< len(s.nested_scenes) {
        if nested_scene_hosts_transform(s, &s.nested_scenes[i], host_tH) {
            ns_lid := s.nested_scenes[i].local_id
            breadcrumb_clear_for_nested_scene(s, ns_lid)
            ordered_remove(&s.nested_scenes, i)
            return
        }
    }
}

scene_nested_scene_by_local_id :: proc(s: ^Scene, ns_local_id: Local_ID) -> (^NestedScene, bool) {
    if s == nil do return nil, false
    for &ns in s.nested_scenes {
        if ns.local_id == ns_local_id do return &ns, true
    }
    return nil, false
}

BREADCRUMB_SYNTH_HANDLE_INDEX_BASE :: u32(0x8000_0000)

breadcrumb_alloc_synthetic_handle :: proc(s: ^Scene) -> Handle {
    s.breadcrumb_synth_seq += 1
    return Handle{
        index      = BREADCRUMB_SYNTH_HANDLE_INDEX_BASE + s.breadcrumb_synth_seq,
        generation = 0,
        type_key   = INVALID_TYPE_KEY,
    }
}

scene_breadcrumb_put :: proc(s: ^Scene, bc: Breadcrumb) -> bool {
    if s == nil || bc.local_id == 0 do return false
    if _, had := s.breadcrumb_data[bc.local_id]; had {
        bimap_remove_by_key(&s.local_ids, bc.local_id)
    }
    h := breadcrumb_alloc_synthetic_handle(s)
    bimap_insert(&s.local_ids, bc.local_id, h)
    s.breadcrumb_data[bc.local_id] = bc
    return true
}

breadcrumb_get :: proc(s: ^Scene, placeholder_local_id: Local_ID) -> (Breadcrumb, bool) {
    if s == nil || placeholder_local_id == 0 do return {}, false
    bc, ok := s.breadcrumb_data[placeholder_local_id]
    return bc, ok
}

breadcrumb_placeholder :: proc(s: ^Scene, scene_instance: Local_ID, src: PPtr) -> (Local_ID, bool) {
    if s == nil || scene_instance == 0 do return 0, false
    for _, bc in s.breadcrumb_data {
        if bc.scene_instance != scene_instance do continue
        if !pptr_equals(bc.scene_source, src) do continue
        return bc.local_id, true
    }
    return 0, false
}

breadcrumb_create :: proc(s: ^Scene, scene_instance: Local_ID, src: PPtr) -> (Local_ID, bool) {
    if s == nil || scene_instance == 0 do return 0, false
    if _, ok := scene_nested_scene_by_local_id(s, scene_instance); !ok do return 0, false
    if ph, ok := breadcrumb_placeholder(s, scene_instance, src); ok {
        return ph, true
    }
    lid := scene_next_id(s)
    if !scene_breadcrumb_put(s, Breadcrumb{
        local_id       = lid,
        scene_source   = src,
        scene_instance = scene_instance,
    }) {
        return 0, false
    }
    return lid, true
}

breadcrumb_materialize_target :: proc(s: ^Scene, scene_instance: Local_ID, target: PPtr) -> (PPtr, bool) {
    if s == nil || scene_instance == 0 do return {}, false
    if pptr_guid_is_empty(target.guid) {
        return target, true
    }
    peg, ok := breadcrumb_create(s, scene_instance, target)
    if !ok do return {}, false
    return PPtr{local_id = peg, guid = Asset_GUID{}}, true
}

breadcrumb_remove :: proc(s: ^Scene, placeholder_local_id: Local_ID) -> bool {
    if s == nil || placeholder_local_id == 0 do return false
    if _, ok := s.breadcrumb_data[placeholder_local_id]; !ok do return false
    bimap_remove_by_key(&s.local_ids, placeholder_local_id)
    delete_key(&s.breadcrumb_data, placeholder_local_id)
    return true
}

breadcrumb_clear_for_nested_scene :: proc(s: ^Scene, scene_instance: Local_ID) {
    if s == nil || scene_instance == 0 do return
    to_del := make([dynamic]Local_ID, 0, 8, context.temp_allocator)
    for _, bc in s.breadcrumb_data {
        if bc.scene_instance == scene_instance {
            append(&to_del, bc.local_id)
        }
    }
    for lid in to_del {
        breadcrumb_remove(s, lid)
    }
}

breadcrumb_is_placeholder :: proc(s: ^Scene, local_id: Local_ID) -> bool {
    if s == nil || local_id == 0 do return false
    _, ok := s.breadcrumb_data[local_id]
    return ok
}
