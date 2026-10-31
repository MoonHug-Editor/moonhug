package animation

// Property channel resolution (clip.odin holds the channel format): turning a
// channel's (component guid, dotted field path) into a live memory location
// and moving [4]f32 values in and out of it.
//
// The value kind derives from the LIVE field typeid at resolve time — the
// file stores untyped floats, so a channel whose component or field no longer
// resolves is skipped (same rule as unresolved transform targets). The one
// undetected edge is a field retyped IN PLACE to another animatable type: old
// float data then applies under the new interpretation.
//
// The resolved location is (component handle, byte offset) — never a cached
// pointer, since pools relocate on growth. Field paths walk plain struct
// nesting only, so the whole chain collapses into one offset from the
// component base.

import "base:runtime"
import "core:encoding/uuid"
import "core:math"
import "core:reflect"
import "core:strings"
import "moonhug:packages/engine"

Prop_Kind :: enum u8 {
	F32,
	Vec2,
	Vec3,
	Vec4,
	Bool,
	Int, // ints and enums
}

// Discrete kinds hold instead of lerp and take the highest-weight contributor
// instead of accumulating in the mixer.
prop_kind_discrete :: proc(kind: Prop_Kind) -> bool {
	return kind == .Bool || kind == .Int
}

// The animatable kind of a field type, unwrapping named aliases. References,
// strings, and structs are not animatable.
_prop_kind_of :: proc(tid: typeid) -> (Prop_Kind, bool) {
	ti := runtime.type_info_base(type_info_of(tid))
	#partial switch v in ti.variant {
	case runtime.Type_Info_Float:
		if ti.size == 4 do return .F32, true
	case runtime.Type_Info_Array:
		elem := runtime.type_info_base(v.elem)
		if _, is_f := elem.variant.(runtime.Type_Info_Float); is_f && elem.size == 4 {
			switch v.count {
			case 2: return .Vec2, true
			case 3: return .Vec3, true
			case 4: return .Vec4, true
			}
		}
	case runtime.Type_Info_Boolean:
		return .Bool, true
	case runtime.Type_Info_Integer:
		return .Int, true
	case runtime.Type_Info_Enum:
		return .Int, true
	}
	return .F32, false
}

// Walk a dotted field path through plain struct nesting, accumulating one
// byte offset from the root. Mirrors the engine's override path walk.
_prop_field_resolve :: proc(tid: typeid, path: string) -> (offset: uintptr, leaf: typeid, ok: bool) {
	cur := tid
	rest := path
	for len(rest) > 0 {
		key := rest
		if dot := strings.index_byte(rest, '.'); dot >= 0 {
			key = rest[:dot]
			rest = rest[dot + 1:]
		} else {
			rest = ""
		}
		names := reflect.struct_field_names(cur)
		types := reflect.struct_field_types(cur)
		offsets := reflect.struct_field_offsets(cur)
		found := false
		for i in 0 ..< len(names) {
			if names[i] != key do continue
			offset += offsets[i]
			cur = types[i].id
			found = true
			break
		}
		if !found do return 0, nil, false
	}
	return offset, cur, true
}

// The inverse of _prop_field_resolve: the dotted path of the field of type
// `want` that starts exactly at byte `offset` inside `tid`, walking plain
// struct nesting the way Add Property lists leaves (identity plumbing `base`
// skipped, reference types never entered). With `want` nil the field is the
// first animatable leaf at that offset. `ok` is whether the field is found and
// animatable. A field that is found but not animatable comes back with its
// path and type and `ok` false, so a caller can name it. The path is
// temp-allocated.
_prop_path_of_offset :: proc(tid: typeid, offset: uintptr, want: typeid) -> (path: string, leaf: typeid, ok: bool) {
	path, leaf = _prop_path_walk(tid, offset, want, "", 0)
	if leaf == nil do return "", nil, false
	_, ok = _prop_kind_of(leaf)
	if ok && _prop_is_reference(leaf) do ok = false
	return
}

@(private = "file")
_prop_path_walk :: proc(tid: typeid, offset: uintptr, want: typeid, prefix: string, depth: int) -> (path: string, leaf: typeid) {
	if depth > 8 do return "", nil
	ti := runtime.type_info_base(type_info_of(tid))
	if _, is_struct := ti.variant.(runtime.Type_Info_Struct); !is_struct do return "", nil
	names := reflect.struct_field_names(tid)
	types := reflect.struct_field_types(tid)
	offsets := reflect.struct_field_offsets(tid)
	for i in 0 ..< len(names) {
		if names[i] == "base" do continue
		lo := offsets[i]
		hi := lo + uintptr(types[i].size)
		if offset < lo || offset >= hi do continue
		ftid := types[i].id
		full := prefix == "" ? names[i] : strings.concatenate({prefix, ".", names[i]}, context.temp_allocator)
		// A reference is one value: an offset inside it names the reference.
		if _prop_is_reference(ftid) {
			if offset == lo do return full, ftid
			return "", nil
		}
		if offset == lo {
			if (want != nil ? ftid == want : _prop_is_animatable(ftid)) do return full, ftid
		}
		if p, l := _prop_path_walk(ftid, offset - lo, want, full, depth + 1); l != nil do return p, l
	}
	return "", nil
}

@(private = "file")
_prop_is_animatable :: proc(tid: typeid) -> bool {
	_, ok := _prop_kind_of(tid)
	return ok
}

@(private = "file")
_prop_is_reference :: proc(tid: typeid) -> bool {
	return tid == typeid_of(engine.PPtr) || tid == typeid_of(engine.Ref) ||
	       tid == typeid_of(engine.Ref_Local) || tid == typeid_of(engine.Owned)
}

// The cacheable half of property resolution: component guid -> type key,
// field path -> byte offset + kind. No world access — binding slots cache
// this and re-fetch only the base pointer each apply (pools relocate).
Prop_Location :: struct {
	type_key: engine.TypeKey,
	offset:   uintptr,
	kind:     Prop_Kind,
	leaf:     typeid,
}

_prop_meta :: proc(component: string, field: string) -> (loc: Prop_Location, ok: bool) {
	guid, gerr := uuid.read(component)
	if gerr != nil do return {}, false
	tid, tok := engine.get_typeid_by_guid_ok(guid)
	if !tok do return {}, false
	key, kok := engine.get_type_key_by_typeid(tid)
	if !kok do return {}, false
	off, leaf_tid, fok := _prop_field_resolve(tid, field)
	if !fok do return {}, false
	k, pok := _prop_kind_of(leaf_tid)
	if !pok do return {}, false
	return {type_key = key, offset = off, kind = k, leaf = leaf_tid}, true
}

// Full resolution against a live transform, for the direct apply path.
// The returned pointer is valid only for the current frame.
_prop_locate :: proc(tH: engine.Transform_Handle, component: string, field: string) -> (ptr: rawptr, kind: Prop_Kind, leaf: typeid, ok: bool) {
	loc, mok := _prop_meta(component, field)
	if !mok do return nil, .F32, nil, false
	_, base := engine.transform_get_comp_key(tH, loc.type_key)
	if base == nil do return nil, .F32, nil, false
	return rawptr(uintptr(base) + loc.offset), loc.kind, loc.leaf, true
}

// Size and signedness of an int or enum leaf, for width-correct load/store.
@(private = "file")
_int_spec :: proc(leaf: typeid) -> (size: int, signed: bool) {
	ti := runtime.type_info_base(type_info_of(leaf))
	#partial switch v in ti.variant {
	case runtime.Type_Info_Integer:
		return ti.size, v.signed
	case runtime.Type_Info_Enum:
		base := runtime.type_info_base(v.base)
		if iv, iok := base.variant.(runtime.Type_Info_Integer); iok {
			return base.size, iv.signed
		}
	}
	return 8, true
}

// Read the live field into [4]f32 lanes (defaults capture).
_prop_read :: proc(ptr: rawptr, kind: Prop_Kind, leaf: typeid) -> [4]f32 {
	v: [4]f32
	switch kind {
	case .F32:  v.x = (cast(^f32)ptr)^
	case .Vec2: v.xy = (cast(^[2]f32)ptr)^
	case .Vec3: v.xyz = (cast(^[3]f32)ptr)^
	case .Vec4: v = (cast(^[4]f32)ptr)^
	case .Bool:
		size, _ := _int_spec(leaf)
		v.x = _load_int(ptr, size, false) != 0 ? 1 : 0
	case .Int:
		size, signed := _int_spec(leaf)
		v.x = f32(_load_int(ptr, size, signed))
	}
	return v
}

// Write [4]f32 lanes back into the live field.
_prop_write :: proc(ptr: rawptr, kind: Prop_Kind, leaf: typeid, v: [4]f32) {
	switch kind {
	case .F32:  (cast(^f32)ptr)^ = v.x
	case .Vec2: (cast(^[2]f32)ptr)^ = v.xy
	case .Vec3: (cast(^[3]f32)ptr)^ = v.xyz
	case .Vec4: (cast(^[4]f32)ptr)^ = v
	case .Bool:
		size, _ := _int_spec(leaf)
		_store_int(ptr, size, v.x > 0.5 ? 1 : 0)
	case .Int:
		size, _ := _int_spec(leaf)
		_store_int(ptr, size, i64(math.round(v.x)))
	}
}

@(private = "file")
_load_int :: proc(ptr: rawptr, size: int, signed: bool) -> i64 {
	switch size {
	case 1: return signed ? i64((cast(^i8)ptr)^) : i64((cast(^u8)ptr)^)
	case 2: return signed ? i64((cast(^i16)ptr)^) : i64((cast(^u16)ptr)^)
	case 4: return signed ? i64((cast(^i32)ptr)^) : i64((cast(^u32)ptr)^)
	case 8: return (cast(^i64)ptr)^
	}
	return 0
}

@(private = "file")
_store_int :: proc(ptr: rawptr, size: int, v: i64) {
	switch size {
	case 1: (cast(^i8)ptr)^ = i8(v)
	case 2: (cast(^i16)ptr)^ = i16(v)
	case 4: (cast(^i32)ptr)^ = i32(v)
	case 8: (cast(^i64)ptr)^ = v
	}
}
