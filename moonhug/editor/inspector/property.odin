package inspector

// An ADDRESSED FIELD (docs/InspectorProperty.md): a field on an object,
// resolved from the owner and a dotted path, carrying everything a write or a
// row needs — the value, the undo owner, the prefab instance an override lands
// on, and the field the override names. Built and discarded within a frame.
//
// The resolver has no imgui in it, so a non-drawing caller (an MCP property
// write) uses the same addressing as the inspector. property_row is the one
// proc here that draws.

import "base:runtime"
import "core:reflect"
import "core:strconv"
import "core:strings"
import engine "../../engine"
import "../undo"

Property :: struct {
    // What the row edits.
    ptr: rawptr,
    tid: typeid,
    tag: reflect.Struct_Tag, // ref: / has: / pick: / ext:

    // The object it belongs to: the undo target, and what offsets measure from.
    owner:  undo.Inspector_Owner,
    base:   rawptr,
    offset: uintptr,

    // Which prefab instance an override lands on. Zero for plain content.
    nested_host: engine.Transform_Handle,
    nested_lid:  engine.Local_ID,

    // What an override NAMES. The value itself for most paths. A path through
    // an array index stops here at the array: an override is the whole array,
    // atomically, and Revert restores all of it.
    record: Override_Field,
}

// Why a path did not resolve. A caller holding a source literal may treat any
// of these as its own bug; a caller fed the path over the wire reports it.
Resolve_Error :: enum {
    None,
    Not_A_Struct,        // a segment names a field on something without fields
    No_Such_Field,       // the struct has no field of that name
    Not_Indexable,       // `[i]` on something that is not an array
    Index_Out_Of_Range,  // `[i]` past the array's length
    Bad_Path,            // malformed: empty segment, unclosed `[`, non-numeric index
}

// A pooled component as an addressable object. Captures the undo owner and
// the prefab context of the component's OWN instance, so a proxy row cannot
// inherit the wrong one (the defect that motivated this). False when the
// handle is dead.
inspect_comp :: proc(comp: engine.Handle) -> (p: Property, ok: bool) {
    o := undo.pooled_owner(comp)
    if o.kind != .Pooled do return {}, false
    p.owner = o
    p.base = o.base_ptr
    p.ptr = o.base_ptr
    p.tid = engine.get_typeid_by_type_key(comp.type_key)
    p.nested_host, p.nested_lid = nested_context_for_comp(comp)
    return p, true
}

// A transform as an addressable object. Prefab context follows the hierarchy
// inspector's rule: the transform is instance content when it is nested-owned
// or is itself an instance host — a host ADDITION is neither.
inspect_transform :: proc(tH: engine.Transform_Handle) -> (p: Property, ok: bool) {
    o := undo.pooled_owner(engine.Handle(tH))
    if o.kind != .Pooled do return {}, false
    t := cast(^engine.Transform)o.base_ptr
    p.owner = o
    p.base = o.base_ptr
    p.ptr = o.base_ptr
    p.tid = typeid_of(engine.Transform)
    is_host := engine.scene_find_nested_scene_for_host(t.scene, tH) != nil
    if t.nested_owned || is_host {
        p.nested_host = engine.transform_immediate_nested_host(tH)
        p.nested_lid = t.local_id
    }
    return p, true
}

// Narrows `p` to the field at `path`: dot-separated names, `[i]` to index a
// fixed or dynamic array, pointers followed. `p.record` is carried forward
// when the path crosses an array — the override stays on the array. Chainable.
property :: proc(p: Property, path: string) -> (out: Property, err: Resolve_Error) {
    out = p
    in_array := p.record.ptr != nil && p.record.ptr != p.ptr
    rest := path
    for len(rest) > 0 {
        // One segment: a name up to `.` or `[`, or an index `[i]`.
        if rest[0] == '[' {
            close := strings.index_byte(rest, ']')
            if close < 0 do return p, .Bad_Path
            idx, iok := strconv.parse_int(rest[1:close])
            if !iok || idx < 0 do return p, .Bad_Path
            rest = rest[close + 1:]
            if len(rest) > 0 && rest[0] == '.' do rest = rest[1:]
            if e := _resolve_index(&out, idx); e != .None do return p, e
            in_array = true
            continue
        }
        end := len(rest)
        if i := strings.index_any(rest, ".["); i >= 0 do end = i
        name := rest[:end]
        if name == "" do return p, .Bad_Path
        rest = rest[end:]
        if len(rest) > 0 && rest[0] == '.' do rest = rest[1:]
        if e := _resolve_field(&out, name); e != .None do return p, e
        if !in_array {
            out.record = {out.ptr, out.tid, _join_path(out.record.path, name)}
        }
    }
    return out, .None
}

// Draws `p` as one row: override marker, the shared row transaction, the
// override record on commit, the right-click menu. Pushes the property's own
// owner, prefab context and picker tags around the row and puts the previous
// ones back, so a row for another component leaves the inspector's context
// untouched. Peers are cleared: a proxy has none of the selection's.
property_row :: proc(
    p:          Property,
    label:      string,
    drawer:     proc(ptr: rawptr, tid: typeid, label: cstring) = nil,
    draw_label: cstring = "",
) -> (finished: bool) {
    undo.push_owner(p.owner)
    prev_host := engine.inspector_set_nested_host(p.nested_host)
    prev_lid := engine.inspector_set_nested_local_id(p.nested_lid)
    prev_tags := field_tags_set(p.tag)
    prev_peers := multi_set_peers(nil)

    d := drawer if drawer != nil else resolve_property_drawer(p.tid)
    dl := draw_label if draw_label != "" else strings.clone_to_cstring(label, context.temp_allocator)
    finished = custom_field_row(p.ptr, p.tid, label, d, dl, p.record)

    multi_set_peers(prev_peers)
    field_tags_restore(prev_tags)
    engine.inspector_set_nested_local_id(prev_lid)
    engine.inspector_set_nested_host(prev_host)
    undo.pop_owner()
    return finished
}

@(private = "file")
_resolve_field :: proc(p: ^Property, name: string) -> Resolve_Error {
    // Follow pointers to the struct they point at.
    tid := p.tid
    ptr := p.ptr
    for {
        ti := runtime.type_info_base(type_info_of(tid))
        pi, is_ptr := ti.variant.(runtime.Type_Info_Pointer)
        if !is_ptr do break
        if pi.elem == nil do return .Not_A_Struct
        ptr = (cast(^rawptr)ptr)^
        if ptr == nil do return .Not_A_Struct
        tid = pi.elem.id
    }
    ti := runtime.type_info_base(type_info_of(tid))
    if _, is_struct := ti.variant.(runtime.Type_Info_Struct); !is_struct do return .Not_A_Struct
    f := reflect.struct_field_by_name(tid, name)
    if f.name == "" do return .No_Such_Field
    p.ptr = rawptr(uintptr(ptr) + f.offset)
    p.tid = f.type.id
    p.tag = f.tag
    p.offset = uintptr(p.ptr) - uintptr(p.base)
    return .None
}

@(private = "file")
_resolve_index :: proc(p: ^Property, idx: int) -> Resolve_Error {
    ti := runtime.type_info_base(type_info_of(p.tid))
    data: rawptr
    count: int
    elem: ^runtime.Type_Info
    #partial switch v in ti.variant {
    case runtime.Type_Info_Array:
        data = p.ptr
        count = v.count
        elem = v.elem
    case runtime.Type_Info_Dynamic_Array:
        da := cast(^runtime.Raw_Dynamic_Array)p.ptr
        data = da.data
        count = da.len
        elem = v.elem
    case:
        return .Not_Indexable
    }
    if idx >= count do return .Index_Out_Of_Range
    p.ptr = rawptr(uintptr(data) + uintptr(idx * elem.size))
    p.tid = elem.id
    p.tag = ""
    p.offset = uintptr(p.ptr) - uintptr(p.base)
    return .None
}

@(private = "file")
_join_path :: proc(prefix, name: string) -> string {
    if prefix == "" do return name
    return strings.concatenate({prefix, ".", name}, context.temp_allocator)
}
