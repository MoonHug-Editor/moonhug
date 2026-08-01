package engine

// Enumerates every override on a prefab instance as a flat, displayable list —
// the model behind the inspector's Overrides dropdown (Unity's equivalent
// lists modified/added/removed components and added GameObjects in one place).
//
// The four record kinds live on the NestedScene in different shapes; this
// flattens them to one row type so the UI can list, multi-select and revert
// without knowing which kind it is holding. Reverting a row dispatches back to
// the kind-specific engine call — see nested_override_entry_revert.
//
// Rows are TEMP-allocated: build them each frame the dropdown is open, the same
// way the rest of the inspector treats derived display data.

import "core:fmt"
import "core:mem"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:strings"

Override_Entry_Kind :: enum {
    Modified_Property,
    Added_Component,
    Removed_Component,
    Added_Object,
    Removed_Object,
}

// One listable override. `object_label`/`detail` are display-only; the fields
// below them are what revert needs to find the record again.
Override_Entry :: struct {
    kind:         Override_Entry_Kind,
    object_label: string, // the affected object, resolved to a live name where possible
    detail:       string, // property path, or the component/object being added/removed

    // The live transform this row hangs under, so the UI can group rows by
    // object and nest them the way the hierarchy does. {} when the object is
    // not materialized — a removed object has no live transform by definition.
    object_tH:    Transform_Handle,

    // Identity of the underlying record.
    target:        PPtr,      // Modified_Property / Removed_Component / Removed_Object
    property_path: string,    // Modified_Property only
    owner:         PPtr,      // Added_Component: the transform it hangs off
    local_id:      Local_ID,  // Added_Component / Added_Object: the record's own lid
}

// Every override recorded on `ns`, in a stable display order: modified
// properties first (grouped by the object they touch), then structural edits.
//
// `ns` must be the NATIVE NS that owns the records — inner NSs never hold any
// (docs/NestedPrefabs.md), so passing one yields an empty list rather than an
// error.
nested_scene_list_overrides :: proc(s: ^Scene, ns: ^NestedScene) -> []Override_Entry {
    out := make([dynamic]Override_Entry, context.temp_allocator)
    if s == nil || ns == nil do return out[:]

    for &ov in ns.overrides {
        label, obj := _override_object_label(s, ns, ov.target)
        append(&out, Override_Entry{
            kind          = .Modified_Property,
            object_label  = label,
            object_tH     = obj,
            detail        = ov.property_path,
            target        = ov.target,
            property_path = ov.property_path,
        })
    }
    for &rc in ns.removed_components {
        label, obj := _override_object_label(s, ns, rc.target)
        append(&out, Override_Entry{
            kind         = .Removed_Component,
            object_label = label,
            object_tH    = obj,
            detail       = "Removed Component",
            target       = rc.target,
        })
    }
    for &ac in ns.added_components {
        label, obj := _override_object_label(s, ns, ac.owner)
        append(&out, Override_Entry{
            kind         = .Added_Component,
            object_label = label,
            object_tH    = obj,
            detail       = fmt.tprintf("Added %s", _component_type_label(ac.type_guid)),
            owner        = ac.owner,
            local_id     = ac.local_id,
        })
    }
    for &ao in ns.added_objects {
        label, obj := _added_object_label(s, ns, ao)
        append(&out, Override_Entry{
            kind         = .Added_Object,
            object_label = label,
            object_tH    = obj,
            detail       = "Added GameObject",
            owner        = ao.parent,
            local_id     = ao.local_id,
        })
    }
    for &ro in ns.removed_objects {
        label, obj := _override_object_label(s, ns, ro.target)
        append(&out, Override_Entry{
            kind         = .Removed_Object,
            object_label = label,
            object_tH    = obj,
            detail       = "Removed GameObject",
            target       = ro.target,
        })
    }
    return out[:]
}

// The live name of the object a record targets. Falls back to the raw lid when
// the object is not materialized — a removed object has no live transform by
// definition, and a stale record may point at a row the prefab no longer has.
@(private = "file")
_override_object_label :: proc(s: ^Scene, ns: ^NestedScene, target: PPtr) -> (string, Transform_Handle) {
    w := ctx_world()

    // Deep targets address a row inside an inner prefab: walk the projection
    // down to the NS that actually owns it, exactly as revert does, so the
    // label names the same object the revert will touch.
    leaf_ns := ns
    leaf_lid := target.local_id
    if !pptr_guid_is_empty(target.guid) && target.guid != ns.source_prefab {
        host := nested_scene_resolve_host_handle(s, ns)
        if _, lns, lid := nested_scene_walk_override_target(s, host, target); lns != nil {
            leaf_ns = lns
            leaf_lid = lid
        }
    }

    if h, hok := bimap_get(&s.local_ids, nested_scene_instance_lid(s, leaf_ns, leaf_lid)); hok {
        if h.type_key == .Transform {
            if t := pool_get(&w.transforms, h); t != nil do return t.name, Transform_Handle(h)
        } else {
            // A component target: name the transform that owns it, since that
            // is what the user recognizes in the hierarchy — and group the row
            // under that object.
            if raw := world_pool_get(w, h); raw != nil {
                base := cast(^CompData)raw
                if ot := pool_get(&w.transforms, Handle(base.owner)); ot != nil {
                    return fmt.tprintf("%s (%v)", ot.name, h.type_key), Transform_Handle(base.owner)
                }
                return fmt.tprintf("%v", h.type_key), {}
            }
        }
    }
    return fmt.tprintf("lid %d", target.local_id), {}
}

// An added object carries its own content, so its name comes from the stored
// fragment when the subtree is not live (e.g. listing before a resolve).
@(private = "file")
_added_object_label :: proc(s: ^Scene, ns: ^NestedScene, ao: Added_Object) -> (string, Transform_Handle) {
    w := ctx_world()
    live := nested_lid_compose(ns.local_id, ao.local_id)
    if h, ok := bimap_get(&s.local_ids, live); ok && h.type_key == .Transform {
        if t := pool_get(&w.transforms, h); t != nil do return t.name, Transform_Handle(h)
    }
    if name, ok := _json_fragment_root_name(ao.json, ao.local_id); ok do return name, {}
    return fmt.tprintf("lid %d", ao.local_id), {}
}

@(private = "file")
_component_type_label :: proc(type_guid: string) -> string {
    guid, err := uuid.read(type_guid)
    if err != nil do return "Component"
    if key, has := _component_registry_by_guid[guid]; has {
        return fmt.tprintf("%v", key)
    }
    return "Component"
}

// The added subtree's root name, read straight from the stored fragment. Used
// when the subtree is not live — the fragment is the only record of it.
@(private = "file")
_json_fragment_root_name :: proc(frag_json: string, root_lid: Local_ID) -> (string, bool) {
    val: json.Value
    if json.unmarshal_string(frag_json, &val, .JSON, context.temp_allocator) != nil do return "", false
    obj, is_obj := val.(json.Object)
    if !is_obj do return "", false
    trs, has := obj["transforms"].(json.Array)
    if !has do return "", false
    for item in trs {
        t_obj, ok := item.(json.Object)
        if !ok do continue
        lid, lok := _json_local_id_of(t_obj)
        if !lok || lid != root_lid do continue
        if name, nok := t_obj["name"].(json.String); nok {
            return strings.clone(string(name), context.temp_allocator), true
        }
    }
    return "", false
}

// Everything needed to put a reverted record back, captured BEFORE the revert
// drops it. The structural kinds carry heap payloads (the component's fields,
// the added subtree's fragment), so the snapshot owns clones — free with
// nested_override_snapshot_destroy, or hand ownership to undo.
Override_Snapshot :: struct {
    kind:      Override_Entry_Kind,
    target:    PPtr,
    owner:     PPtr,
    local_id:  Local_ID,
    type_guid: string, // Added_Component (owned)
    json:      string, // Added_Component / Added_Object (owned)
    valid:     bool,
}

nested_override_snapshot :: proc(ns: ^NestedScene, e: Override_Entry) -> Override_Snapshot {
    snap := Override_Snapshot{kind = e.kind, target = e.target, owner = e.owner, local_id = e.local_id}
    if ns == nil do return snap
    #partial switch e.kind {
    case .Added_Component:
        for &ac in ns.added_components {
            if ac.local_id != e.local_id do continue
            snap.type_guid = strings.clone(ac.type_guid)
            snap.json = strings.clone(ac.json)
            snap.valid = true
            return snap
        }
    case .Added_Object:
        for &ao in ns.added_objects {
            if ao.local_id != e.local_id do continue
            snap.json = strings.clone(ao.json)
            snap.valid = true
            return snap
        }
    case .Removed_Component, .Removed_Object:
        // Target-only records: identity IS the payload.
        snap.valid = true
    }
    return snap
}

nested_override_snapshot_destroy :: proc(snap: ^Override_Snapshot) {
    if snap.type_guid != "" do delete(snap.type_guid)
    if snap.json != "" do delete(snap.json)
    snap.type_guid = ""
    snap.json = ""
    snap.valid = false
}

// Restores a reverted FIELD override: the record AND the live value.
//
// nested_scene_restore_override alone only puts the record back. That is enough
// for the property menu's Revert, whose paired Value_Command restores the value
// — the dropdown has no such pair, so undoing it that way would leave the field
// reading as overridden while holding its baseline, and the following redo
// would look like a no-op.
nested_override_restore_field :: proc(
    s: ^Scene,
    ns: ^NestedScene,
    target: PPtr,
    property_path: string,
    value_json: []byte,
) -> bool {
    if s == nil || ns == nil do return false
    if !nested_scene_restore_override(ns, target, property_path, value_json) do return false

    // Locate the live field the same way revert does, so the two agree on
    // which object a deep target names.
    leaf_ns := ns
    leaf_lid := target.local_id
    if !pptr_guid_is_empty(target.guid) && target.guid != ns.source_prefab {
        host := nested_scene_resolve_host_handle(s, ns)
        if _, lns, lid := nested_scene_walk_override_target(s, host, target); lns != nil {
            leaf_ns = lns
            leaf_lid = lid
        }
    }
    for &ov in ns.overrides {
        if !pptr_equals(ov.target, target) || ov.property_path != property_path do continue
        nested_scene_patch_live_field(s, leaf_ns, leaf_lid, property_path, ov.value)
        break
    }
    return true
}

// Puts a structural record back. The inverse of nested_override_entry_revert
// for everything except Modified_Property, whose restore already exists as
// nested_scene_restore_override (it also has to restore the field VALUE).
nested_override_snapshot_restore :: proc(ns: ^NestedScene, snap: Override_Snapshot) -> bool {
    if ns == nil || !snap.valid do return false
    #partial switch snap.kind {
    case .Removed_Component:
        for &rc in ns.removed_components {
            if pptr_equals(rc.target, snap.target) do return false // already back
        }
        append(&ns.removed_components, Removed_Component{target = snap.target})
        return true
    case .Removed_Object:
        for &ro in ns.removed_objects {
            if pptr_equals(ro.target, snap.target) do return false
        }
        append(&ns.removed_objects, Removed_Object{target = snap.target})
        return true
    case .Added_Component:
        return nested_scene_restore_component_added(ns, snap.owner, snap.local_id, snap.type_guid, snap.json)
    case .Added_Object:
        for &ao in ns.added_objects {
            if ao.local_id == snap.local_id do return false
        }
        append(&ns.added_objects, Added_Object{
            parent   = snap.owner,
            local_id = snap.local_id,
            json     = strings.clone(snap.json),
        })
        return true
    }
    return false
}

// Reverts one listed override, dispatching on its kind. Returns false when the
// record is already gone (a stale row from a list built before another revert).
//
// Field reverts restore the base VALUE as well as dropping the record; the
// structural kinds only drop the record, because the next resolve rebuilds the
// instance from the prefab and that is what puts the content back.
nested_override_entry_revert :: proc(s: ^Scene, ns: ^NestedScene, e: Override_Entry) -> bool {
    if s == nil || ns == nil do return false
    // The entry already carries the record's resolved identity, so each kind
    // removes from `ns` directly. The nested_scene_unrecord_* entry points take
    // a LIVE host handle and re-derive the target, which is what the editor's
    // structural edit paths have; going through them here would re-project a
    // target we already hold.
    switch e.kind {
    case .Modified_Property:
        if !nested_scene_has_override(ns, e.target, e.property_path) do return false
        nested_scene_revert_override(s, ns, e.target, e.property_path)
        return true
    case .Removed_Component:
        for i in 0 ..< len(ns.removed_components) {
            if !pptr_equals(ns.removed_components[i].target, e.target) do continue
            ordered_remove(&ns.removed_components, i)
            return true
        }
    case .Added_Component:
        for i in 0 ..< len(ns.added_components) {
            if ns.added_components[i].local_id != e.local_id do continue
            ac := ns.added_components[i]
            delete(ac.type_guid)
            delete(ac.json)
            ordered_remove(&ns.added_components, i)
            return true
        }
    case .Removed_Object:
        for i in 0 ..< len(ns.removed_objects) {
            if !pptr_equals(ns.removed_objects[i].target, e.target) do continue
            ordered_remove(&ns.removed_objects, i)
            return true
        }
    case .Added_Object:
        for i in 0 ..< len(ns.added_objects) {
            if ns.added_objects[i].local_id != e.local_id do continue
            delete(ns.added_objects[i].json)
            ordered_remove(&ns.added_objects, i)
            return true
        }
    }
    return false
}

// --- Tree view ---------------------------------------------------------------

// One node of the dropdown's tree: an object, the override rows that belong to
// it, then its child objects. Depth is the indent level.
//
// An object with no overrides of its own can still appear, when a DESCENDANT
// has them — the path has to be walkable. Those nodes are `has_own == false`:
// the UI draws them disabled, but they stay selectable so "revert this object"
// can mean "revert everything beneath it".
Override_Node :: struct {
    tH:       Transform_Handle,
    label:    string,
    depth:    int,
    has_own:  bool,  // this object owns at least one row
    rows:     []int, // indices into the entries slice passed to the builder

    // The object's rows collapsed to one entry per COMPONENT. The list shows
    // these, not individual fields — several changed fields on one component
    // read as one element, the way Unity groups overrides.
    groups:   []Override_Group,

    // Rows on the TRANSFORM itself (and structural rows about this object).
    // They belong to the object element, which already represents the
    // transform — there is no separate "Transform" child.
    own_rows: []int,
}

// One listable element under an object: everything overridden on a single
// component (or on the transform). `rows` are the underlying records, so
// reverting the group reverts each of them.
Override_Group :: struct {
    label:    string,
    type_key: TypeKey, // INVALID_TYPE_KEY = the transform itself
    kind:     Override_Entry_Kind,
    rows:     []int,
}

// Groups `entries` by object and orders them as a hierarchy: each object node,
// then its rows, then its children. Objects are linked by walking live parents
// up to the instance host, so intermediate objects without overrides of their
// own are included as disabled nodes.
//
// Rows whose object is not live (a removed object, or a stale record) are
// emitted as depth-0 nodes of their own — there is no hierarchy to place them
// in, and dropping them would hide a real override.
nested_scene_override_tree :: proc(
    s: ^Scene,
    ns: ^NestedScene,
    host_tH: Transform_Handle,
    entries: []Override_Entry,
) -> []Override_Node {
    out := make([dynamic]Override_Node, context.temp_allocator)
    if s == nil do return out[:]
    w := ctx_world()
    ns_arg := ns

    // Rows per object, plus every ancestor up to the host so the tree is
    // connected even where the intermediate objects are clean.
    // The live tree already links objects to the host, so grouping only needs
    // rows-per-object — the walk below finds the intermediates.
    rows_of := make(map[Transform_Handle][dynamic]int, 0, context.temp_allocator)

    orphans := make([dynamic]int, context.temp_allocator)
    for e, i in entries {
        if e.object_tH == {} {
            append(&orphans, i)
            continue
        }
        if _, has := rows_of[e.object_tH]; !has {
            rows_of[e.object_tH] = make([dynamic]int, context.temp_allocator)
        }
        arr := &rows_of[e.object_tH]
        append(arr, i)
    }

    // Depth-first from the host so siblings keep hierarchy order.
    _emit :: proc(
        w: ^World,
        tH: Transform_Handle,
        depth: int,
        rows_of: ^map[Transform_Handle][dynamic]int,
        entries: []Override_Entry,
        s: ^Scene,
        ns: ^NestedScene,
        out: ^[dynamic]Override_Node,
    ) {
        t := pool_get(&w.transforms, Handle(tH))
        if t == nil do return

        // Include this object only if it, or anything BELOW it, has rows —
        // checking direct children only would drop a clean object whose sole
        // overridden descendant is a grandchild.
        own, has_own := rows_of[tH]
        if !has_own && !_subtree_has_rows(w, tH, rows_of) do return

        rows: []int
        if has_own do rows = own[:]
        append(out, Override_Node{
            tH = tH, label = t.name, depth = depth, has_own = has_own, rows = rows,
            groups = _group_rows_by_owner(s, ns, rows, entries),
            own_rows = _transform_own_rows(s, ns, rows, entries),
        })

        for child in t.children {
            _emit(w, Transform_Handle(child.handle), depth + 1, rows_of, entries, s, ns, out)
        }
    }
    _emit(w, host_tH, 0, &rows_of, entries, s, ns_arg, &out)

    // Rows with no live object: their own top-level nodes.
    for i in orphans {
        rows := slice_one_temp(i)
        append(&out, Override_Node{
            label = entries[i].object_label, depth = 0, has_own = true,
            rows = rows, groups = _group_rows_by_owner(s, ns, rows, entries),
            own_rows = _transform_own_rows(s, ns, rows, entries),
        })
    }
    return out[:]
}

// Whether anything strictly below `tH` owns a row.
@(private = "file")
_subtree_has_rows :: proc(
    w: ^World,
    tH: Transform_Handle,
    rows_of: ^map[Transform_Handle][dynamic]int,
) -> bool {
    t := pool_get(&w.transforms, Handle(tH))
    if t == nil do return false
    for child in t.children {
        ch := Transform_Handle(child.handle)
        if _, has := rows_of[ch]; has do return true
        if _subtree_has_rows(w, ch, rows_of) do return true
    }
    return false
}

@(private = "file")
slice_one_temp :: proc(i: int) -> []int {
    out := make([]int, 1, context.temp_allocator)
    out[0] = i
    return out
}

// --- Prefab-side values for the comparison view -------------------------------

// A temp copy of the object as the PREFAB defines it, for the read-only left
// pane of the dropdown's comparison view. The bytes come from the same
// chain-baked baseline revert diffs against, so the two panes disagree exactly
// where an override exists.
//
// `ptr` points at a scratch instance of the type `tid` names, temp-allocated —
// valid until the frame's free_all, which is the lifetime a drawer needs.
Override_Baseline :: struct {
    ptr:   rawptr,
    tid:   typeid,
    label: string,
    ok:    bool,
}

// The baseline for a transform row, or for one component on it. `type_key` of
// INVALID_TYPE_KEY asks for the transform itself.
nested_override_baseline :: proc(
    s: ^Scene,
    ns: ^NestedScene,
    target: PPtr,
    type_key: TypeKey = INVALID_TYPE_KEY,
) -> Override_Baseline {
    if s == nil || ns == nil do return {}

    // Resolve deep targets to the NS that owns the row, as revert does.
    leaf_ns := ns
    leaf_lid := target.local_id
    if !pptr_guid_is_empty(target.guid) && target.guid != ns.source_prefab {
        host := nested_scene_resolve_host_handle(s, ns)
        if _, lns, lid := nested_scene_walk_override_target(s, host, target); lns != nil {
            leaf_ns = lns
            leaf_lid = lid
        }
    }

    raw, ok := chain_baked_base_for_ns(s, leaf_ns)
    if !ok do return {}
    defer delete(raw)

    sf: SceneFile
    if scene_file_unmarshal(raw, &sf) != nil do return {}
    defer scene_file_destroy(&sf)

    if type_key == INVALID_TYPE_KEY {
        for &t in sf.transforms {
            if t.local_id != leaf_lid do continue
            out := new(Transform, context.temp_allocator)
            out^ = t
            // The scratch copy outlives sf's teardown only for the fields a
            // drawer reads; the name is the one heap field, so clone it.
            out.name = strings.clone(t.name, context.temp_allocator)
            out.children = nil
            out.components = nil
            return {ptr = out, tid = typeid_of(Transform), label = "Transform", ok = true}
        }
        return {}
    }

    // A component baseline: find the record whose lid matches, then unmarshal
    // it into a scratch instance of its registered type. The record carries its
    // own guid tag, so the type comes from the registry rather than the caller.
    for rec in sf.components {
        obj, is_obj := rec.(json.Object)
        if !is_obj do continue
        if _json_component_lid_of(obj) != leaf_lid do continue
        desc, dok := _ext_desc_for_value(rec)
        if !dok || desc.type_key != type_key do continue

        ti := type_info_of(desc.tid)
        if ti == nil do return {}
        block, aerr := mem.alloc(ti.size, ti.align, context.temp_allocator)
        if aerr != nil || block == nil do return {}
        if !_ext_value_into(desc, rec, block) do return {}
        return {
            ptr   = block,
            tid   = desc.tid,
            label = fmt.tprintf("%v", type_key),
            ok    = true,
        }
    }
    return {}
}

// The LIVE object an override target names: the transform itself, or the
// component on it. The comparison view needs this so both panes describe the
// same thing — the baseline is looked up by the same identity.
nested_override_live_handle :: proc(s: ^Scene, ns: ^NestedScene, target: PPtr) -> Handle {
    if s == nil || ns == nil do return {}
    leaf_ns := ns
    leaf_lid := target.local_id
    if !pptr_guid_is_empty(target.guid) && target.guid != ns.source_prefab {
        host := nested_scene_resolve_host_handle(s, ns)
        if _, lns, lid := nested_scene_walk_override_target(s, host, target); lns != nil {
            leaf_ns = lns
            leaf_lid = lid
        }
    }
    if h, ok := bimap_get(&s.local_ids, nested_scene_instance_lid(s, leaf_ns, leaf_lid)); ok {
        return h
    }
    return {}
}

// Collapses an object's rows to one element per owning COMPONENT. Fields on the
// transform itself are NOT a group — the object element already represents the
// transform, so they attach to it via Override_Node.own_rows and would be a
// duplicate "Transform" child otherwise.
//
// Field rows on the same component merge into one group; structural rows stay
// one element each, since "Added SpriteRenderer" is already component-granular.
@(private = "file")
_group_rows_by_owner :: proc(
    s: ^Scene,
    ns: ^NestedScene,
    rows: []int,
    entries: []Override_Entry,
) -> []Override_Group {
    if len(rows) == 0 do return nil
    out := make([dynamic]Override_Group, context.temp_allocator)

    for ri in rows {
        e := entries[ri]

        // Which component (if any) owns the overridden field. Structural kinds
        // name their own subject, so they never merge.
        key := INVALID_TYPE_KEY
        label := e.detail
        if e.kind == .Modified_Property {
            h := nested_override_live_handle(s, ns, e.target)
            // A transform field belongs to the object element itself.
            if h == {} || h.type_key == .Transform do continue
            key = h.type_key
            label = fmt.tprintf("%v", h.type_key)

            merged := false
            for &g in out {
                if g.kind != .Modified_Property || g.type_key != key do continue
                rs := make([dynamic]int, context.temp_allocator)
                append(&rs, ..g.rows)
                append(&rs, ri)
                g.rows = rs[:]
                merged = true
                break
            }
            if merged do continue
        }

        append(&out, Override_Group{
            label = label, type_key = key, kind = e.kind, rows = slice_one_temp(ri),
        })
    }
    return out[:]
}

// The rows that belong to the object element itself: fields on the transform,
// plus structural rows whose subject IS this object (a removed/added object).
@(private = "file")
_transform_own_rows :: proc(
    s: ^Scene,
    ns: ^NestedScene,
    rows: []int,
    entries: []Override_Entry,
) -> []int {
    if len(rows) == 0 do return nil
    out := make([dynamic]int, context.temp_allocator)
    for ri in rows {
        e := entries[ri]
        if e.kind != .Modified_Property do continue
        h := nested_override_live_handle(s, ns, e.target)
        if h == {} || h.type_key == .Transform do append(&out, ri)
    }
    return out[:]
}
