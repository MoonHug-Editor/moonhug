package engine_tests

// A union whose variants are literal types (f32, [3]f32, bool) next to
// declared ones: a literal variant saves tagged with its text and its value
// under `__value`, a struct variant keeps its fields next to its guid, and a
// declared non-struct variant (an enum) saves its guid and its `__value`.

import "core:encoding/json"
import "core:encoding/uuid"
import "core:strings"
import "core:testing"
import core "moonhug:libs/core"
import serialization "moonhug:libs/serialization"
import common "moonhug:tests/common"

@(private = "file")
_Lit_Struct :: struct {
	a: f32,
	b: string,
}

@(private = "file")
_Lit_Enum :: enum {
	Red,
	Blue,
}

@(private = "file")
_Lit_Union :: union #no_nil {
	f32,
	[3]f32,
	bool,
	_Lit_Struct,
	_Lit_Enum,
}

@(private = "file")
_round_trip :: proc(t: ^testing.T, v: _Lit_Union, want_text: string) -> _Lit_Union {
	v := v
	data, merr := json.marshal(v, {spec = .JSON}, context.temp_allocator)
	testing.expectf(t, merr == nil, "%v marshals: %v", v, merr)
	testing.expectf(t, strings.contains(string(data), want_text), "%v saves as %s, want it to hold %s", v, string(data), want_text)
	back: _Lit_Union
	uerr := json.unmarshal(data, &back, .JSON, context.temp_allocator)
	testing.expectf(t, uerr == nil, "%s loads: %v", string(data), uerr)
	return back
}

@(test)
test_union_literal_variants_round_trip :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	@(static) registered: bool
	if !registered {
		registered = true
		s, _ := uuid.read("6f0e1c52-4a7b-4c4e-9d1a-2b7c8e5f3a01")
		e, _ := uuid.read("6f0e1c52-4a7b-4c4e-9d1a-2b7c8e5f3a02")
		core.register_type(_Lit_Struct, s)
		core.register_type(_Lit_Enum, e)
		serialization.register_union_type(_Lit_Union)
	}

	testing.expect_value(t, _round_trip(t, f32(0.6), `{"__type":"f32","__value":0.6`), _Lit_Union(f32(0.6)))
	testing.expect_value(t, _round_trip(t, [3]f32{0, 2.5, 0}, `{"__type":"[3]f32","__value":[0`), _Lit_Union([3]f32{0, 2.5, 0}))
	testing.expect_value(t, _round_trip(t, true, `{"__type":"bool","__value":true}`), _Lit_Union(true))
	testing.expect_value(t, _round_trip(t, _Lit_Enum.Blue, `"__type_guid":"6f0e1c52-4a7b-4c4e-9d1a-2b7c8e5f3a02","__value":`), _Lit_Union(_Lit_Enum.Blue))

	// A struct variant keeps the merged form every saved union has today.
	got := _round_trip(t, _Lit_Struct{a = 3, b = "hi"}, `{"__type_guid":"6f0e1c52-4a7b-4c4e-9d1a-2b7c8e5f3a01","a":3`)
	st, is_struct := got.(_Lit_Struct)
	testing.expect(t, is_struct && st.a == 3 && st.b == "hi", "the struct variant loads back with its fields")

	// A literal type no registered union has is dangling data: an error, not a crash.
	back: _Lit_Union
	err := json.unmarshal(transmute([]u8)string(`{"__type":"[7]f64","__value":[1,2,3,4,5,6,7]}`), &back, .JSON, context.temp_allocator)
	testing.expect(t, err != nil, "an unknown literal type does not load")

	text, ok := serialization.literal_type_text([4]f32)
	testing.expect(t, ok && text == "[4]f32", "a literal type's text is how the language spells it")
	_, declared := serialization.literal_type_text(_Lit_Enum)
	testing.expect(t, !declared, "a declared type has no literal text")
}
