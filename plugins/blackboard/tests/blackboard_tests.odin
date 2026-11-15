package blackboard_tests

// The Blackboard component as the slots library's scope: a slot on an object
// takes an entry from the nearest Blackboard on the object or above it, then
// from further up, then from the game-wide dictionary.

import "core:strings"
import "core:testing"
import "moonhug:libs/slots"
import blackboard "moonhug:packages/blackboard"
import "moonhug:packages/engine"
import common "moonhug:tests/common"

@(private = "file")
_board :: proc(t: ^testing.T, object: engine.Transform_Handle) -> ^blackboard.Blackboard {
	_, ptr := engine.transform_add_comp(object, .Blackboard)
	testing.expect(t, ptr != nil, "a Blackboard can be added")
	return cast(^blackboard.Blackboard)ptr
}

@(private = "file")
_number :: proc(b: ^blackboard.Blackboard, name: string, value: f32) {
	append(&b.entries, blackboard.Blackboard_Entry{name = strings.clone(name), type = .Number, number = value})
}

@(test)
test_blackboard_lookup_up_the_tree :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	root := engine.transform_new("Root")
	enemy := engine.transform_new("Enemy", root)
	legs := engine.transform_new("Legs", enemy)
	other := engine.transform_new("Other")

	on_root := _board(t, root)
	_number(on_root, "bb_speed", 1)
	_number(on_root, "bb_far", 9)
	on_enemy := _board(t, enemy)
	_number(on_enemy, "bb_speed", 2)

	speed := slots.entry("bb_speed")
	far := slots.entry("bb_far")
	// The nearest Blackboard's entry wins, the one further up fills in.
	testing.expect_value(t, slots.get(speed, f32(0), slots.scope_of(legs)), 2)
	testing.expect_value(t, slots.get(far, f32(0), slots.scope_of(legs)), 9)
	testing.expect_value(t, slots.get(speed, f32(0), slots.scope_of(root)), 1)
	// No Blackboard above: the inline value.
	testing.expect_value(t, slots.get(speed, f32(7), slots.scope_of(other)), 7)
	// The game-wide dictionary is last in the chain.
	slots.set(slots.global(), "bb_global", f32(5))
	defer slots.remove(slots.global(), "bb_global")
	testing.expect_value(t, slots.get(slots.entry("bb_global"), f32(0), slots.scope_of(legs)), 5)
}

@(test)
test_blackboard_authored_edit_is_read_again :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	enemy := engine.transform_new("Enemy")
	b := _board(t, enemy)
	_number(b, "bb_edit", 1)
	s := slots.entry("bb_edit")
	testing.expect_value(t, slots.get(s, f32(0), slots.scope_of(enemy)), 1)
	// As the inspector edits it: in place, with nothing told.
	b.entries[0].number = 4
	testing.expect_value(t, slots.get(s, f32(0), slots.scope_of(enemy)), 4)
	// Another type under the same name: the slot's type no longer fits.
	b.entries[0].type = .Flag
	_, ok := slots.lookup(slots.entry("bb_edit"), bool, slots.scope_of(enemy))
	testing.expect(t, ok, "the entry is a flag now")
}

@(test)
test_blackboard_set_and_unset :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	enemy := engine.transform_new("Enemy")
	legs := engine.transform_new("Legs", enemy)
	lone := engine.transform_new("Lone")
	b := _board(t, enemy)
	_number(b, "bb_hp", 10)
	s := slots.entry("bb_hp")

	testing.expect(t, blackboard.set(legs, "bb_hp", f32(3)), "set reaches the Blackboard above the object")
	testing.expect_value(t, slots.get(s, f32(0), slots.scope_of(legs)), 3)
	testing.expect_value(t, b.entries[0].number, 10) // the authored entry is not touched
	testing.expect(t, blackboard.unset(legs, "bb_hp"), "unset reaches it too")
	testing.expect_value(t, slots.get(s, f32(0), slots.scope_of(legs)), 10)
	testing.expect(t, !blackboard.set(lone, "bb_hp", f32(3)), "no Blackboard on the object or above it")
}

@(test)
test_blackboard_offers_entries_by_type :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	root := engine.transform_new("Root")
	enemy := engine.transform_new("Enemy", root)
	on_root := _board(t, root)
	_number(on_root, "bb_a", 1)
	_number(on_root, "bb_b", 1)
	append(&on_root.entries, blackboard.Blackboard_Entry{name = strings.clone("bb_tint"), type = .Color})
	on_enemy := _board(t, enemy)
	_number(on_enemy, "bb_a", 2)

	numbers := slots.scope_entries(enemy, f32)
	testing.expect_value(t, len(numbers), 2)
	if len(numbers) == 2 {
		// Nearest first, and a name once: the entry a slot would get.
		testing.expect_value(t, numbers[0].name, "bb_a")
		testing.expect_value(t, numbers[0].from, "Enemy")
		testing.expect_value(t, numbers[1].name, "bb_b")
		testing.expect_value(t, numbers[1].from, "Root")
	}
	testing.expect_value(t, len(slots.scope_entries(enemy, [4]f32)), 1)
	testing.expect_value(t, len(slots.scope_entries(enemy, [3]f32)), 0)
}
