package engine_tests

// Slots (moonhug/libs/slots): a value read inline or from a dictionary, the
// dictionary's chain, computed entries, and how a slot saves.

import "core:encoding/json"
import "core:strings"
import "core:testing"
import "moonhug:libs/slots"

@(test)
test_slot_inline_and_connected :: proc(t: ^testing.T) {
	d: slots.Dict
	defer slots.destroy(&d)
	slots.set(&d, "test_slot_speed", f32(3))

	testing.expect_value(t, slots.get(slots.INLINE, f32(1), &d), 1)
	testing.expect_value(t, slots.get(slots.entry("test_slot_speed"), f32(1), &d), 3)
	// No dictionary has the entry: the inline value.
	testing.expect_value(t, slots.get(slots.entry("test_slot_absent"), f32(1), &d), 1)
	// No dictionary at all, as in an edit-mode preview.
	testing.expect_value(t, slots.get(slots.entry("test_slot_speed"), f32(1), nil), 1)

	slots.remove(&d, "test_slot_speed")
	testing.expect_value(t, slots.get(slots.entry("test_slot_speed"), f32(1), &d), 1)
}

@(test)
test_slot_dictionary_chain :: proc(t: ^testing.T) {
	game, run: slots.Dict
	defer slots.destroy(&game)
	defer slots.destroy(&run)
	run.parent = &game
	slots.set(&game, "test_slot_dir", [3]f32{1, 0, 0})
	slots.set(&game, "test_slot_shared", i32(7))
	slots.set(&run, "test_slot_dir", [3]f32{0, 1, 0})

	testing.expect_value(t, slots.get(slots.entry("test_slot_dir"), [3]f32{}, &run), [3]f32{0, 1, 0})
	testing.expect_value(t, slots.get(slots.entry("test_slot_shared"), i32(0), &run), 7)
	testing.expect_value(t, slots.get(slots.entry("test_slot_dir"), [3]f32{}, &game), [3]f32{1, 0, 0})
	testing.expect(t, slots.has(slots.entry("test_slot_shared"), &run), "the chain has the parent's entry")
	testing.expect(t, !slots.has(slots.INLINE, &run), "an unconnected slot names no entry")
}

@(test)
test_slot_computed_entry :: proc(t: ^testing.T) {
	d: slots.Dict
	defer slots.destroy(&d)
	counter: i32
	slots.set_proc(&d, "test_slot_counter", i32, proc(out: ^i32, user: rawptr) {
		c := cast(^i32)user
		c^ += 1
		out^ = c^
	}, &counter)

	s := slots.entry("test_slot_counter")
	testing.expect_value(t, slots.get(s, i32(0), &d), 1)
	testing.expect_value(t, slots.get(s, i32(0), &d), 2)
}

@(test)
test_slot_wrong_type_reads_inline :: proc(t: ^testing.T) {
	d: slots.Dict
	defer slots.destroy(&d)
	slots.set(&d, "test_slot_typed", f32(3))
	_, ok := slots.lookup(slots.entry("test_slot_typed"), [3]f32, &d)
	testing.expect(t, !ok, "an entry of another type is not handed out")
}

@(test)
test_slot_declared_entries :: proc(t: ^testing.T) {
	slots.declare("test_slot_decl_a", [2]i32, "first")
	slots.declare("test_slot_decl_b", [2]i32)
	slots.declare("test_slot_decl_a", [2]i32, "again")
	found_a, found_b: int
	for d in slots.declared_of([2]i32) {
		if d.name == "test_slot_decl_a" {
			found_a += 1
			testing.expect_value(t, d.doc, "again")
		}
		if d.name == "test_slot_decl_b" do found_b += 1
	}
	testing.expect_value(t, found_a, 1)
	testing.expect_value(t, found_b, 1)
}

_Slot_Holder :: struct {
	speed:  slots.Slot,
	_speed: f32 `inspect:"-"`,
	tint:   slots.Slot,
	_tint:  [4]f32 `inspect:"-"`,
}

// A slot saves as its entry's name, an empty string when not connected, and
// loads back to the same slot.
@(test)
test_slot_saves_by_name :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)

	h := _Slot_Holder{speed = slots.entry("test_slot_saved"), _speed = 2, _tint = {1, 0, 0, 1}}
	data, merr := json.marshal(h, {spec = .JSON}, context.temp_allocator)
	testing.expect(t, merr == nil, "marshals")
	text := string(data)
	testing.expectf(t, strings.contains(text, `"speed":"test_slot_saved"`), "the connected slot saves as its name: %s", text)
	testing.expectf(t, strings.contains(text, `"tint":""`), "the unconnected slot saves as an empty string: %s", text)

	back: _Slot_Holder
	uerr := json.unmarshal(data, &back, allocator = context.temp_allocator)
	testing.expect(t, uerr == nil, "unmarshals")
	testing.expect_value(t, back.speed, h.speed)
	testing.expect_value(t, back.tint, slots.INLINE)
	testing.expect_value(t, back._speed, 2)
}
