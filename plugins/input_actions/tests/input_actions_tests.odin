#+feature dynamic-literals
package input_actions_tests

// The input actions runtime: controls parse, buttons and composites resolve
// from the input library's frame and fixed views, the map stack answers by
// priority, and a map consumes all of the controls below it or only its
// listed actions' ones.

import "core:os"
import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"
import "moonhug:editor/undo"
import "moonhug:libs/input"
import "moonhug:libs/serialization"
import "moonhug:packages/engine"
import actions ".."

@(private = "file")
_key_event :: proc(k: input.Key, down: bool) {
	e: sdl.Event
	e.type = down ? .KEY_DOWN : .KEY_UP
	e.key.scancode = k
	input.apply_event(&e)
}

// A Player map (Jump, Move) under a Menu map (Confirm on the same key as
// Jump, consuming all), and a Gun map that consumes only Fire's control.
@(private = "file")
_asset :: proc() -> actions.Input_Actions {
	a: actions.Input_Actions
	player: actions.Mapping_Context = {name = "Player", priority = 0, consume = .Listed}
	append(&player.actions, actions.Action{name = "Jump", value_type = .Digital, mappings = {{key = "key:SPACE"}, {key = "pad:SOUTH"}}})
	append(&player.actions, actions.Action{name = "Move", value_type = .Axis2D, mappings = {
		{key = "key:W", modifier = .Up}, {key = "key:S", modifier = .Down},
		{key = "key:A", modifier = .Left}, {key = "key:D", modifier = .Right},
		{key = "pad:LEFT_STICK"},
	}})
	append(&player.actions, actions.Action{name = "Zoom", value_type = .Axis1D, mappings = {{key = "key:E", modifier = .Positive}, {key = "key:Q", modifier = .Negative}}})
	gun: actions.Mapping_Context = {name = "Gun", priority = 5, consume = .Listed}
	append(&gun.actions, actions.Action{name = "Fire", value_type = .Digital, consume_input = true, mappings = {{key = "key:SPACE"}}})
	menu: actions.Mapping_Context = {name = "Menu", priority = 100, consume = .All}
	append(&menu.actions, actions.Action{name = "Confirm", value_type = .Digital, mappings = {{key = "key:SPACE"}}})
	append(&a.contexts, player, gun, menu)
	// The literals above are not heap strings: clone them, so the asset owns
	// its text as a loaded one does and cleanup_Input_Actions frees it.
	for &m in a.contexts {
		m.name = strings.clone(m.name)
		for &ac in m.actions {
			ac.name = strings.clone(ac.name)
			for &km in ac.mappings do km.key = actions.Key_Name(strings.clone(string(km.key)))
		}
	}
	return a
}

@(test)
test_asset_round_trip :: proc(t: ^testing.T) {
	a := _asset()
	defer actions.cleanup_Input_Actions(&a)
	path := "moonhug/tests/fixtures/_input_actions_round_trip.asset"
	defer os.remove(path)
	testing.expect(t, serialization.write_asset_to_path(path, engine.get_guid_by_typeid(actions.Input_Actions), a), "the asset writes")
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, rerr == nil, "the file reads")
	back, bok := engine.asset_parse_as(data, actions.Input_Actions)
	testing.expect(t, bok, "and parses back")
	defer actions.cleanup_Input_Actions(&back)
	testing.expect_value(t, len(back.contexts), 3)
	testing.expect_value(t, string(back.contexts[0].actions[0].mappings[0].key), "key:SPACE")
	testing.expect_value(t, back.contexts[2].priority, 100)
	testing.expect(t, len(actions.key_names()) > 100, "the picker lists every control")
}

@(test)
test_key_parse :: proc(t: ^testing.T) {
	c, ok := actions.key_parse("key:SPACE")
	testing.expect(t, ok && c.kind == .Key && c.key == .SPACE)
	c, ok = actions.key_parse("mouse:Left")
	testing.expect(t, ok && c.kind == .Mouse_Button && c.button == .Left)
	c, ok = actions.key_parse("pad:LEFT_STICK")
	testing.expect(t, ok && c.kind == .Pad_Stick && c.pad_axis == .LEFTX)
	c, ok = actions.key_parse("pad:LEFT_TRIGGER")
	testing.expect(t, ok && c.kind == .Pad_Axis && c.pad_axis == .LEFT_TRIGGER)
	c, ok = actions.key_parse("pad:NORTH")
	testing.expect(t, ok && c.kind == .Pad_Button && c.pad_button == .NORTH)
	_, ok = actions.key_parse("key:NO_SUCH_KEY")
	testing.expect(t, !ok, "an unknown name fails")
	_, ok = actions.key_parse("SPACE")
	testing.expect(t, !ok, "a name without a device fails")
}

@(test)
test_actions_resolve_and_stack :: proc(t: ^testing.T) {
	a := _asset()
	defer actions.cleanup_Input_Actions(&a)
	actions.actions_install(a)
	defer actions.actions_reset()
	// The fixed accumulators record edges only while the app is focused.
	input.set_app_focused(true)
	defer input.set_app_focused(false)
	input.frame_reset()
	defer { _key_event(.SPACE, false); _key_event(.W, false); _key_event(.D, false); _key_event(.E, false); input.frame_reset() }

	jump := actions.action_id("Player", "Jump")
	move := actions.action_id("Player", "Move")
	zoom := actions.action_id("Player", "Zoom")
	fire := actions.action_id("Gun", "Fire")
	confirm := actions.action_id("Menu", "Confirm")

	// Nothing pushed: nothing resolves.
	_key_event(.SPACE, true)
	actions.actions_resolve_frame(0)
	testing.expect(t, !actions.down(jump), "an unpushed map reads nothing")

	actions.context_push("Player")
	actions.actions_resolve_frame(0)
	testing.expect(t, actions.down(jump) && actions.pressed(jump), "the first frame down is a press")
	actions.actions_resolve_frame(0)
	testing.expect(t, actions.down(jump) && !actions.pressed(jump), "held is not a press")
	_key_event(.SPACE, false)
	actions.actions_resolve_frame(0)
	testing.expect(t, !actions.down(jump) && actions.released(jump), "the release is one edge")

	// Composites: W and D give (1, 1), E gives +1.
	_key_event(.W, true)
	_key_event(.D, true)
	_key_event(.E, true)
	actions.actions_resolve_frame(0)
	testing.expect_value(t, actions.value2(move), [2]f32{1, 1})
	testing.expect_value(t, actions.value(zoom), f32(1))
	testing.expect(t, actions.down(move), "an axis with a value is down")

	// Gun over Player: Fire takes SPACE, Jump no longer sees it. Move stays.
	actions.context_push("Gun")
	_key_event(.SPACE, true)
	actions.actions_resolve_frame(0)
	testing.expect(t, actions.down(fire), "the pushed map answers")
	testing.expect(t, !actions.down(jump), "a listed consume takes only that control")
	testing.expect_value(t, actions.value2(move), [2]f32{1, 1})

	// Menu over everything: it takes every control.
	actions.context_push("Menu")
	actions.actions_resolve_frame(0)
	testing.expect(t, actions.down(confirm))
	testing.expect(t, !actions.down(fire) && !actions.down(jump), "consume all blocks the maps below")
	testing.expect_value(t, actions.value2(move), [2]f32{0, 0})
	pushed := actions.contexts_pushed()
	testing.expect_value(t, len(pushed), 3)
	testing.expect_value(t, pushed[0], "Menu")
	testing.expect_value(t, pushed[1], "Gun")

	// Pop Menu: the maps below see their controls again, with a fresh press.
	actions.context_pop("Menu")
	actions.actions_resolve_frame(0)
	testing.expect(t, !actions.down(confirm), "a popped map reads nothing")
	testing.expect(t, actions.down(fire) && actions.pressed(fire), "the control comes back as a new press")
	actions.context_pop("Gun")
	actions.actions_resolve_frame(0)
	testing.expect(t, actions.down(jump), "Jump sees SPACE again")

	// The fixed view: a tap between ticks still reads as a press on the tick.
	// The press from above is still pending for the fixed view: one tick
	// consumes it, the next reads the key up.
	_key_event(.SPACE, false)
	input.fixed_latch()
	actions.actions_resolve_fixed(0)
	input.fixed_latch()
	actions.actions_resolve_fixed(0)
	testing.expect(t, !actions.down_fixed(jump))
	_key_event(.SPACE, true)
	_key_event(.SPACE, false)
	input.fixed_latch()
	actions.actions_resolve_fixed(0)
	testing.expect(t, actions.down_fixed(jump) && actions.pressed_fixed(jump), "a tap between ticks is one press")
	input.fixed_latch()
	actions.actions_resolve_fixed(0)
	testing.expect(t, actions.released_fixed(jump))
}

@(test)
test_dead_zone :: proc(t: ^testing.T) {
	a: actions.Input_Actions
	m: actions.Mapping_Context = {name = strings.clone("M"), consume = .All}
	append(&m.actions, actions.Action{name = strings.clone("Look"), value_type = .Axis2D, dead_zone = 0.5, mappings = {{key = actions.Key_Name(strings.clone("mouse:Delta")), scalar = 0.1}}})
	append(&a.contexts, m)
	defer actions.cleanup_Input_Actions(&a)
	actions.actions_install(a)
	defer actions.actions_reset()
	actions.context_push("M")
	e: sdl.Event
	e.type = .MOUSE_MOTION
	e.motion.xrel = 3
	e.motion.yrel = 0
	input.frame_reset()
	input.apply_event(&e)
	actions.actions_resolve_frame(0)
	testing.expect_value(t, actions.value2(actions.action_id("M", "Look")), [2]f32{0, 0})
	e.motion.xrel = 7
	input.apply_event(&e)
	actions.actions_resolve_frame(0)
	testing.expect_value(t, actions.value2(actions.action_id("M", "Look")), [2]f32{1, 0})
	input.frame_reset()
}

// A key cell written back through undo's JSON path, the path the inspector's
// picker rows take: the key type has a pointer type, and the old text is
// freed before the new one is read in (the tracking allocator reports a leak
// or a bad free otherwise).
@(test)
test_key_name_undo_write :: proc(t: ^testing.T) {
	km := actions.Key_Mapping{key = actions.Key_Name(strings.clone("key:A")), scalar = 1}
	defer delete(string(km.key))
	testing.expect(t, undo.write_json_value(&km.key, typeid_of(actions.Key_Name), transmute([]u8)string(`"key:LSHIFT"`), {}), "the key writes back")
	testing.expect_value(t, string(km.key), "key:LSHIFT")
	testing.expect(t, undo.write_json_value(&km.modifier, typeid_of(actions.Modifier), transmute([]u8)string(`3`), {}), "an enum cell writes back")
	testing.expect_value(t, km.modifier, actions.Modifier.Up)
}
