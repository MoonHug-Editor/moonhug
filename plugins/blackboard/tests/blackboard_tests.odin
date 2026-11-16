package blackboard_tests

// The Blackboard component as the slots library's scope: a slot on an object
// takes an entry from the nearest Blackboard on the object or above it, then
// from further up, then from the game-wide dictionary. Slots connect to an
// entry's id, which stays through a rename.

import "core:fmt"
import "core:strings"
import "core:testing"
import core "moonhug:libs/core"
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

// A Number entry with a new id, and the slot that connects to it.
@(private = "file")
_number :: proc(b: ^blackboard.Blackboard, name: string, value: f32) -> slots.Slot {
	e := blackboard.entry_add(b, name)
	e.value = value
	return blackboard.entry_key(e)
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
	speed := _number(on_root, "speed", 1)
	far := _number(on_root, "far", 9)
	// The enemy's Blackboard stands in for the root's speed: the same id.
	on_enemy := _board(t, enemy)
	blackboard.entry_override(on_enemy, &on_root.entries[0]).value = f32(2)

	testing.expect_value(t, slots.get(speed, f32(0), slots.scope_of(legs)), 2)
	testing.expect_value(t, slots.get(far, f32(0), slots.scope_of(legs)), 9)
	testing.expect_value(t, slots.get(speed, f32(0), slots.scope_of(root)), 1)
	// No Blackboard above: the inline value.
	testing.expect_value(t, slots.get(speed, f32(7), slots.scope_of(other)), 7)
	// The game-wide dictionary is last in the chain, its entries keyed by name.
	slots.set(slots.global(), "bb_global", f32(5))
	defer slots.remove(slots.global(), "bb_global")
	testing.expect_value(t, slots.get(slots.entry("bb_global"), f32(0), slots.scope_of(legs)), 5)
}

// A slot connects to an entry's id: a rename breaks nothing, and an entry of
// another Blackboard with the same name is another entry.
@(test)
test_blackboard_rename_keeps_connections :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	enemy := engine.transform_new("Enemy")
	legs := engine.transform_new("Legs", enemy)
	b := _board(t, enemy)
	speed := _number(b, "speed", 3)
	testing.expect_value(t, slots.label(legs, speed), "speed")

	delete(b.entries[0].name)
	b.entries[0].name = strings.clone("pace")
	testing.expect_value(t, slots.get(speed, f32(0), slots.scope_of(legs)), 3)
	testing.expect_value(t, slots.label(legs, speed), "pace")

	// A second entry called speed is not what the slot was connected to.
	again := _number(b, "speed", 8)
	testing.expect(t, again != speed, "an entry made anew has an id of its own")
	testing.expect_value(t, slots.get(speed, f32(0), slots.scope_of(legs)), 3)
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
	s := _number(b, "edit", 1)
	testing.expect_value(t, slots.get(s, f32(0), slots.scope_of(enemy)), 1)
	// As the inspector edits it: in place, with nothing told.
	b.entries[0].value = f32(4)
	testing.expect_value(t, slots.get(s, f32(0), slots.scope_of(enemy)), 4)
	// Another type for the same entry: it is a flag now.
	b.entries[0].value = true
	_, ok := slots.lookup(s, bool, slots.scope_of(enemy))
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
	s := _number(b, "hp", 10)

	// Code names the entry, and the name finds its id.
	testing.expect(t, blackboard.set(legs, "hp", f32(3)), "set reaches the Blackboard above the object")
	testing.expect_value(t, slots.get(s, f32(0), slots.scope_of(legs)), 3)
	testing.expect_value(t, b.entries[0].value, blackboard.Blackboard_Value(f32(10))) // the authored entry is not touched
	testing.expect(t, blackboard.unset(legs, "hp"), "unset reaches it too")
	testing.expect_value(t, slots.get(s, f32(0), slots.scope_of(legs)), 10)
	testing.expect(t, !blackboard.set(lone, "hp", f32(3)), "no Blackboard on the object or above it")
	// A name no entry has is an entry of its own, keyed by the name.
	testing.expect(t, blackboard.set(legs, "bb_code_only", f32(6)), "set of a name no entry has")
	testing.expect_value(t, slots.get(slots.entry("bb_code_only"), f32(0), slots.scope_of(legs)), 6)
}

// A slot's write goes to the Blackboard that holds the entry, so every
// reader under it gets the value, and the authored entry stays as it was.
// A nearer Blackboard's override of the entry is an entry of its own.
@(test)
test_blackboard_write_through_a_slot :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	squad := engine.transform_new("Squad")
	medic := engine.transform_new("Medic", squad)
	bar := engine.transform_new("Bar", squad)
	leader := engine.transform_new("Leader", squad)
	guard := engine.transform_new("Guard", leader)
	on_squad := _board(t, squad)
	hp := _number(on_squad, "hp", 10)

	testing.expect(t, slots.write(hp, f32(4), slots.scope_of(medic)), "the medic writes through its slot")
	testing.expect_value(t, slots.get(hp, f32(0), slots.scope_of(bar)), 4)
	value, ok := blackboard.get(bar, "hp", f32)
	testing.expect(t, ok, "get finds the entry by name")
	testing.expect_value(t, value, 4)
	testing.expect_value(t, on_squad.entries[0].value, blackboard.Blackboard_Value(f32(10))) // the authored entry is not touched

	// An edit of the entries rebuilds what is authored: the write stays over it.
	on_squad.entries[0].value = f32(20)
	testing.expect_value(t, slots.get(hp, f32(0), slots.scope_of(bar)), 4)

	// The leader's Blackboard overrides hp: a write under it stays there.
	on_leader := _board(t, leader)
	blackboard.entry_override(on_leader, &on_squad.entries[0]).value = f32(50)
	testing.expect(t, slots.write(hp, f32(45), slots.scope_of(guard)), "the guard writes the override")
	testing.expect_value(t, slots.get(hp, f32(0), slots.scope_of(guard)), 45)
	testing.expect_value(t, slots.get(hp, f32(0), slots.scope_of(bar)), 4)

	_, wrong := blackboard.get(bar, "hp", i32)
	testing.expect(t, !wrong, "get of another type")
	_, none := blackboard.get(bar, "bb_no_such_entry", f32)
	testing.expect(t, !none, "get of a name nothing has")
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
	a := _number(on_root, "a", 1)
	b := _number(on_root, "b", 1)
	tint := blackboard.entry_add(on_root, "tint")
	tint.value = blackboard.value_new([4]f32)
	on_enemy := _board(t, enemy)
	testing.expect_value(t, len(blackboard.entries_above(on_enemy)), 3)
	blackboard.entry_override(on_enemy, &on_root.entries[0])
	// What is left to stand in for: b and tint.
	testing.expect_value(t, len(blackboard.entries_above(on_enemy)), 2)

	numbers := slots.scope_entries(enemy, f32)
	testing.expect_value(t, len(numbers), 2)
	if len(numbers) == 2 {
		// Nearest first, and an entry once: the one a slot would get.
		testing.expect_value(t, numbers[0].slot, a)
		testing.expect_value(t, numbers[0].from, "Enemy")
		testing.expect_value(t, numbers[1].slot, b)
		testing.expect_value(t, numbers[1].from, "Root")
	}
	testing.expect_value(t, len(slots.scope_entries(enemy, [4]f32)), 1)
	testing.expect_value(t, len(slots.scope_entries(enemy, [3]f32)), 0)
}

// A value written over an entry does not outlive a change of the entry's
// type: readers of the new type get the authored value, and can write it.
@(test)
test_blackboard_written_value_goes_when_the_type_changes :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	enemy := engine.transform_new("Enemy")
	b := _board(t, enemy)
	hp := _number(b, "hp", 10)
	testing.expect(t, slots.write(hp, f32(4), slots.scope_of(enemy)), "a number is written")
	testing.expect_value(t, slots.get(hp, f32(0), slots.scope_of(enemy)), 4)

	b.entries[0].value = i32(7) // the designer makes it an Integer
	testing.expect_value(t, slots.get(hp, i32(0), slots.scope_of(enemy)), 7)
	testing.expect(t, slots.write(hp, i32(5), slots.scope_of(enemy)), "an integer is written")
	testing.expect_value(t, slots.get(hp, i32(0), slots.scope_of(enemy)), 5)
}

// A child of `parent` named `name`, {} for none.
@(private = "file")
_child :: proc(parent: engine.Transform_Handle, name: string) -> engine.Transform_Handle {
	t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(parent))
	if t == nil do return {}
	for c in t.children {
		ct := engine.pool_get(&engine.ctx_world().transforms, c.handle)
		if ct != nil && ct.name == name do return engine.Transform_Handle(c.handle)
	}
	return {}
}

// Every built-in value type saves and loads, and an Object entry names the
// object it named: after a reload, and in a duplicate, the copy's own object.
@(test)
test_blackboard_values_save_and_load :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	root := engine.transform_new("Level")
	engine.scene_set_root(tc.scene, root)
	squad := engine.transform_new("Squad", root)
	target := engine.transform_new("Target", squad)
	target_lid := engine.pool_get(&tc.world.transforms, engine.Handle(target)).local_id
	b := _board(t, squad)
	values := [?]blackboard.Blackboard_Value{
		f32(1.5),
		i32(-3),
		true,
		[2]f32{1, 2},
		[3]f32{0, 2.5, 0},
		[4]f32{1, 0, 0, 1},
		core.PPtr{local_id = 7, guid = core.Asset_GUID{1, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}},
		core.Ref{pptr = {local_id = target_lid}, handle = engine.Handle(target)},
	}
	for v, i in values do blackboard.entry_add(b, fmt.tprintf("v%d", i)).value = v

	data, ok := engine.scene_serialize(tc.scene)
	testing.expect(t, ok, "the scene saves")
	if !ok do return
	defer delete(data)
	reloaded := engine.scene_reload_in_place_bytes(tc.scene, data)
	testing.expect(t, reloaded != nil, "the scene loads")
	if reloaded == nil do return
	tc.scene = reloaded

	squad = _child(engine.Transform_Handle(reloaded.root.handle), "Squad")
	target, _ = engine.scene_find_selectable_transform_local_id(reloaded, target_lid)
	b = blackboard.nearest(squad)
	testing.expect(t, b != nil && len(b.entries) == len(values), "the entries load")
	if b == nil || len(b.entries) != len(values) do return
	for v, i in values[:7] do testing.expectf(t, b.entries[i].value == v, "entry %d is %v, want %v", i, b.entries[i].value, v)
	ref, is_ref := b.entries[7].value.(core.Ref)
	testing.expect(t, is_ref && ref.handle == engine.Handle(target), "the Object entry names the loaded object")
	// Read through a slot, as a reader under the Blackboard does.
	testing.expect_value(t, slots.get(blackboard.entry_key(&b.entries[4]), [3]f32{}, slots.scope_of(target)), [3]f32{0, 2.5, 0})

	copy := engine.scene_duplicate_subtree(squad)
	copy_target := _child(copy, "Target")
	cb := blackboard.nearest(copy)
	testing.expect(t, copy_target != {} && cb != nil && cb != b, "the duplicate has its own Target and Blackboard")
	if cb == nil || len(cb.entries) != len(values) do return
	copy_ref, _ := cb.entries[7].value.(core.Ref)
	testing.expect(t, copy_ref.handle == engine.Handle(copy_target), "the copy's Object entry names the copy's Target")
}
