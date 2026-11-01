package animation

// Property channel resolution (clip.odin holds the channel format): turning a
// channel's (component guid, dotted field path) into a live memory location
// and moving key values (Channel_Value) in and out of it.
//
// The value kind derives from the LIVE field typeid at resolve time, so a
// channel whose component or field no longer resolves is skipped (same rule
// as unresolved transform targets). A row whose kind does not fit the field
// writes nothing, except that floats and ints convert into each other. The
// one undetected edge is a field retyped IN PLACE to another animatable type
// of the same row kind: old data then applies under the new interpretation.
//
// The resolved location is (component handle, byte offset) — never a cached
// pointer, since pools relocate on growth. Field paths walk plain struct
// nesting only, so the whole chain collapses into one offset from the
// component base.

import "base:runtime"
import "core:encoding/uuid"
import "core:fmt"
import "core:math"
import "core:reflect"
import "core:strings"
import "moonhug:packages/engine"

// The kind of an animatable field. F32 to Vec4 key a float row, Bool and Int
// an i64 row, Ref a PPtr row, Text a string row.
Prop_Kind :: enum u8 {
	F32,
	Vec2,
	Vec3,
	Vec4,
	Bool,
	Int,  // ints and enums
	Ref,  // an engine.PPtr or engine.Asset_GUID field
	Text, // a string field
}

// Discrete kinds hold instead of lerp and take the highest-weight contributor
// instead of accumulating in the mixer.
prop_kind_discrete :: proc(kind: Prop_Kind) -> bool {
	switch kind {
	case .Bool, .Int, .Ref, .Text: return true
	case .F32, .Vec2, .Vec3, .Vec4:
	}
	return false
}

// How many float lanes a field of `kind` has: 2 to 4 for a vector, 1 for
// every other kind (a scalar, or an int, bool, reference or string in one
// value).
prop_kind_lanes :: proc(kind: Prop_Kind) -> int {
	switch kind {
	case .Vec2: return 2
	case .Vec3: return 3
	case .Vec4: return 4
	case .F32, .Bool, .Int, .Ref, .Text:
	}
	return 1
}

// --- Lane masks ------------------------------------------------------------------
//
// A float row of 2, 3 or 4 lanes animates only the lanes outside its
// `lanes_off` (Animation_Channel). The mask needs the row's width, which a
// property row only has once its field resolves, so these take the field's
// kind: a transform row ignores it (Position, Scale and Euler are 3 lanes,
// Rotation 4), a property row is as wide as prop_kind_lanes says.
//   - a Rotation row and a scalar row ignore the mask: every lane animates
//   - a lane past the row's width is never off
//   - all lanes off is a valid file but nothing writes one: the window removes
//     the row when its last lane goes

// How many lanes row `ch` has on a field of `kind`.
animation_channel_lane_count :: proc(ch: ^Animation_Channel, kind: Prop_Kind) -> int {
	if !animation_channel_is_property(ch) do return ch.path == .Rotation ? 4 : 3
	if !animation_channel_is_float(ch) do return 1
	return prop_kind_lanes(kind)
}

// Whether row `ch` on a field of `kind` reads its lane mask: a float row of 2
// to 4 lanes that is not a Rotation row.
animation_channel_lanes_maskable :: proc(ch: ^Animation_Channel, kind: Prop_Kind) -> bool {
	if !animation_channel_is_float(ch) do return false
	if !animation_channel_is_property(ch) && ch.path == .Rotation do return false
	return animation_channel_lane_count(ch, kind) >= 2
}

// The lanes row `ch` leaves alone on a field of `kind`: its mask inside its
// width, empty for a row that ignores the mask.
animation_channel_lanes_off :: proc(ch: ^Animation_Channel, kind: Prop_Kind) -> Lane_Set {
	if !animation_channel_lanes_maskable(ch, kind) do return {}
	width: Lane_Set
	for l in 0 ..< animation_channel_lane_count(ch, kind) do width += {l}
	return Lane_Set(ch.lanes_off) & width
}

// Whether lane `lane` of row `ch` animates on a field of `kind`. False past
// the row's width.
animation_channel_lane_on :: proc(ch: ^Animation_Channel, kind: Prop_Kind, lane: int) -> bool {
	if lane < 0 || lane >= animation_channel_lane_count(ch, kind) do return false
	return lane not_in animation_channel_lanes_off(ch, kind)
}

// The number of lanes row `ch` can mask, resolving a property row's field
// through the type registry (no world needed): 2 to 4, or 0 for a row with no
// mask (Rotation, scalar, discrete, or a property that does not resolve).
// The Animation window's lane rows and lane menus read this.
animation_channel_mask_width :: proc(ch: ^Animation_Channel) -> int {
	kind := Prop_Kind.Vec3
	if animation_channel_is_property(ch) {
		loc, ok := _prop_meta(ch.component, ch.field)
		if !ok do return 0
		kind = loc.kind
	}
	if !animation_channel_lanes_maskable(ch, kind) do return 0
	return animation_channel_lane_count(ch, kind)
}

// The animatable kind of a field type, unwrapping named aliases. PPtr and
// Asset_GUID are Ref. Every other reference type (Ref, Ref_Local, Owned) and
// plain structs are not animatable.
_prop_kind_of :: proc(tid: typeid) -> (Prop_Kind, bool) {
	if tid == typeid_of(engine.PPtr) || tid == typeid_of(engine.Asset_GUID) do return .Ref, true
	ti := runtime.type_info_base(type_info_of(tid))
	if ti.id == typeid_of(string) do return .Text, true
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
		// A reference is one value: an offset inside it names the reference
		// (animatable for a PPtr, not for the others).
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

// Size and signedness of an int, enum or bool leaf, for width-correct
// load/store. A bool is one byte (b8, b16 and b32 their own size): a wider
// store would write over the fields after it.
@(private = "file")
_int_spec :: proc(leaf: typeid) -> (size: int, signed: bool) {
	ti := runtime.type_info_base(type_info_of(leaf))
	#partial switch v in ti.variant {
	case runtime.Type_Info_Boolean:
		return ti.size, false
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

// Read a float, bool or int field into [4]f32 lanes (a bool or int in the
// first lane). A Ref or Text field has no lanes: _prop_read_value reads
// every kind.
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
	case .Ref, .Text:
		fmt.panicf("animation: a %v field has no float lanes", kind)
	}
	return v
}

// Write [4]f32 lanes back into a float, bool or int field.
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
	case .Ref, .Text:
		fmt.panicf("animation: a %v field has no float lanes", kind)
	}
}

// Read the live field as the key value its row holds: floats for F32 to Vec4,
// i64 for Bool and Int, a PPtr for Ref (an Asset_GUID field reads with local
// id 0), the field's own string for Text (borrowed, not cloned).
_prop_read_value :: proc(ptr: rawptr, kind: Prop_Kind, leaf: typeid) -> Channel_Value {
	switch kind {
	case .F32, .Vec2, .Vec3, .Vec4:
		return _prop_read(ptr, kind, leaf)
	case .Bool:
		size, _ := _int_spec(leaf)
		return i64(_load_int(ptr, size, false) != 0 ? 1 : 0)
	case .Int:
		size, signed := _int_spec(leaf)
		return _load_int(ptr, size, signed)
	case .Ref:
		if leaf == typeid_of(engine.Asset_GUID) do return engine.PPtr{guid = (cast(^engine.Asset_GUID)ptr)^}
		return (cast(^engine.PPtr)ptr)^
	case .Text:
		return (cast(^string)ptr)^
	}
	unreachable()
}

// Write a key value into the live field. Floats and ints convert into each
// other (the first lane, rounded). A value of any other kind than the field's
// writes nothing: the row no longer matches the field's type.
//
// A float write leaves the lanes in `keep` as the field holds them: it reads
// the field, replaces the other lanes and writes the result back. A row's
// lane mask arrives here (animation_channel_lanes_off). Other kinds ignore
// `keep`.
//
// A Text field owns its string on the process allocator, as every component
// string does (scene load, undo, the inspector and component cleanup use
// context.allocator outside temp scopes). The string lives in the component
// across frames, so a write under the temp allocator (a preview that
// evaluates in a temp scope) uses runtime.default_allocator() instead. A new
// value frees the old string and stores a clone. An equal value writes
// nothing, so a held key does not allocate every frame.
_prop_write_value :: proc(ptr: rawptr, kind: Prop_Kind, leaf: typeid, v: Channel_Value, keep: Lane_Set = {}) {
	switch kind {
	case .F32, .Vec2, .Vec3, .Vec4:
		f: [4]f32
		#partial switch x in v {
		case [4]f32: f = x
		case i64:    f = {f32(x), 0, 0, 0}
		case:        return
		}
		if keep != {} {
			cur := _prop_read(ptr, kind, leaf)
			for l in keep do f[l] = cur[l]
		}
		_prop_write(ptr, kind, leaf, f)
	case .Bool:
		size, _ := _int_spec(leaf)
		#partial switch x in v {
		case i64:    _store_int(ptr, size, x != 0 ? 1 : 0)
		case [4]f32: _store_int(ptr, size, x.x > 0.5 ? 1 : 0)
		}
	case .Int:
		size, _ := _int_spec(leaf)
		#partial switch x in v {
		case i64:    _store_int(ptr, size, x)
		case [4]f32: _store_int(ptr, size, i64(math.round(x.x)))
		}
	case .Ref:
		x, ok := v.(engine.PPtr)
		if !ok do return
		if leaf == typeid_of(engine.Asset_GUID) {
			(cast(^engine.Asset_GUID)ptr)^ = x.guid
		} else {
			(cast(^engine.PPtr)ptr)^ = x
		}
	case .Text:
		x, ok := v.(string)
		if !ok do return
		field := cast(^string)ptr
		if field^ == x do return
		owner := context.allocator
		if owner.data == context.temp_allocator.data do owner = runtime.default_allocator()
		delete(field^, owner)
		field^ = strings.clone(x, owner)
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
