package tests

// The menu tree as an API surface, not just a UI. MCP list_menus and
// invoke_menu read it, and global shortcuts walk it, so what it reports as
// invokable and what it actually fires have to agree — a path that lists but
// will not fire is worse than one that never appeared.

import "core:slice"
import "core:testing"
import "../editor/menu"

@(private = "file") _act_ran: int
@(private = "file") _act_flag: bool
@(private = "file") _act_disabled: int

@(private = "file") _run_act :: proc() { _act_ran += 1 }
@(private = "file") _run_disabled :: proc() { _act_disabled += 1 }
@(private = "file") _never :: proc() -> bool { return false }

@(private = "file")
_has :: proc(paths: []string, want: string) -> bool {
	for p in paths do if p == want do return true
	return false
}

// A fresh tree per test: init_menu resets the global root, and these paths
// must not collide with the editor's own. Pair every call with
// menu.shutdown_menu(), or the replaced tree is leaked.
@(private = "file")
_fixture :: proc() {
	menu.init_menu()
	_act_ran, _act_disabled = 0, 0
	_act_flag = false
	menu.add_menu_item("T/Act", "", _run_act)
	menu.add_menu_item("T/Off", "", _run_disabled, menu.ORDER_DEFAULT, _never)
	menu.add_menu_toggle("T/Flag", &_act_flag)
}

// Toggles are as clickable as actions. Leaving them out of the listing made
// them unreachable AND undiscoverable through the bridge.
@(test)
test_menu_lists_toggles_with_actions :: proc(t: ^testing.T) {
	_fixture()
	defer menu.shutdown_menu()
	paths := menu.collect_invokable_paths()
	testing.expect(t, _has(paths, "T/Act"), "actions are listed")
	testing.expect(t, _has(paths, "T/Flag"), "toggles are listed too")
	// A submenu is a container, not something to fire.
	testing.expect(t, !_has(paths, "T"), "the parent submenu is not invokable")
}

// Everything listed must fire. The two procs share _node_invokable so they
// cannot drift into disagreeing.
@(test)
test_menu_every_listed_path_invokes :: proc(t: ^testing.T) {
	_fixture()
	defer menu.shutdown_menu()
	for p in menu.collect_invokable_paths() {
		// "T/Off" is listed but disabled — being disabled is a live predicate,
		// not a property of the path, so it belongs in the listing and refuses
		// at call time.
		ok, _ := menu.invoke_path(p)
		if p == "T/Off" {
			testing.expect(t, !ok, "a disabled item refuses")
			continue
		}
		testing.expectf(t, ok, "%s listed but did not invoke", p)
	}
	testing.expect_value(t, _act_ran, 1)
	testing.expect_value(t, _act_disabled, 0)
}

// A toggle flips and reports where it landed: there is no way to read menu
// state from outside, and asking twice would put it back.
@(test)
test_menu_invoke_toggle_flips_and_reports :: proc(t: ^testing.T) {
	_fixture()
	defer menu.shutdown_menu()
	testing.expect(t, !_act_flag)

	ok, state := menu.invoke_path("T/Flag")
	testing.expect(t, ok)
	testing.expect(t, state, "the reply carries the value AFTER the flip")
	testing.expect(t, _act_flag, "and the flip actually happened")

	ok2, state2 := menu.invoke_path("T/Flag")
	testing.expect(t, ok2 && !state2, "flipping again puts it back")
	testing.expect(t, !_act_flag)
}

@(test)
test_menu_invoke_rejects_non_items :: proc(t: ^testing.T) {
	_fixture()
	defer menu.shutdown_menu()
	no_path, _ := menu.invoke_path("T/Nope")
	testing.expect(t, !no_path, "an unknown path does not invoke")
	submenu, _ := menu.invoke_path("T")
	testing.expect(t, !submenu, "a submenu is not invokable")
	disabled, _ := menu.invoke_path("T/Off")
	testing.expect(t, !disabled, "the enabled predicate is honored")
	testing.expect_value(t, _act_disabled, 0)
}

// Paths are stable text an agent stores between calls, so the listing must not
// depend on registration order.
@(test)
test_menu_listing_is_deterministic :: proc(t: ^testing.T) {
	_fixture()
	defer menu.shutdown_menu()
	first := slice.clone(menu.collect_invokable_paths(), context.temp_allocator)
	second := menu.collect_invokable_paths()
	testing.expect_value(t, len(first), len(second))
	for p, i in first do testing.expect_value(t, p, second[i])
}
