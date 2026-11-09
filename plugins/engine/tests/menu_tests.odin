package engine_tests

// The menu tree as an API surface, not just a UI. MCP list_menus and
// invoke_menu read it, and global shortcuts walk it, so what it reports as
// invokable and what it actually fires have to agree — a path that lists but
// will not fire is worse than one that never appeared.

import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import core "moonhug:libs/core"
import "moonhug:packages/engine"
import "moonhug:editor"
import "moonhug:editor/icons"
import "moonhug:editor/menu"
import "moonhug:editor/session"

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

// --- Per-window menu and tab bar (editor/window_chrome.odin) ---------------------
//
// Window items live in their own registry, not the main menu tree. That must not
// make them unreachable: anything driving the editor from outside addresses
// them as "Window Menu/<window>/<label>".

@(private = "file") _window_flag: bool
@(private = "file") _window_ran: int
@(private = "file") _window_act :: proc(window: session.Window_Ref) { _window_ran += 1 }
@(private = "file") _window_flip :: proc(window: session.Window_Ref) { _window_flag = !_window_flag }
@(private = "file") _window_is_flipped :: proc(window: session.Window_Ref) -> bool { return _window_flag }
@(private = "file") _window_never :: proc(window: session.Window_Ref) -> bool { return false }

@(private = "file")
_window_fixture :: proc() {
	editor.window_chrome_shutdown()
	_window_flag = false
	_window_ran = 0
	editor.window_menu_add_toggle("Console", "Clear on Play", &_window_flag)
	editor.window_menu_add_action("Console", "Reset", _window_act)
	editor.window_menu_add_action("Console", "Never", _window_act, 0, _window_never)
	editor.window_tab_bar_add_item("Output", _window_act, 0)
}

@(test)
test_window_menu_paths_are_addressable :: proc(t: ^testing.T) {
	_window_fixture()
	defer editor.window_chrome_shutdown()

	paths := editor.window_menu_paths()
	testing.expect(t, _has(paths, "Window Menu/Console/Clear on Play"), "a toggle is addressable")
	testing.expect(t, _has(paths, "Window Menu/Console/Reset"), "an action is addressable")
}

@(test)
test_window_menu_invoke_matches_clicking :: proc(t: ^testing.T) {
	_window_fixture()
	defer editor.window_chrome_shutdown()

	ok, state := editor.window_menu_invoke("Window Menu/Console/Clear on Play")
	testing.expect(t, ok && state, "a toggle flips and reports where it landed")
	testing.expect(t, _window_flag)
	_, state2 := editor.window_menu_invoke("Window Menu/Console/Clear on Play")
	testing.expect(t, !state2, "flipping again puts it back")

	act, _ := editor.window_menu_invoke("Window Menu/Console/Reset")
	testing.expect(t, act)
	testing.expect_value(t, _window_ran, 1)

	// An action carrying a tick predicate is a toggle whose state lives
	// elsewhere, so invoking it reports that state rather than a flat false.
	editor.window_menu_add_action("Console", "Ticked", _window_flip, 0, nil, _window_is_flipped)
	_, ticked := editor.window_menu_invoke("Window Menu/Console/Ticked")
	testing.expect(t, ticked, "an action with checked reports its state")
	_, unticked := editor.window_menu_invoke("Window Menu/Console/Ticked")
	testing.expect(t, !unticked, "and reports it again after flipping back")

	// The enabled predicate is honored, so a disabled item refuses rather than
	// running quietly.
	off, _ := editor.window_menu_invoke("Window Menu/Console/Never")
	testing.expect(t, !off, "a disabled window item refuses")
	testing.expect_value(t, _window_ran, 1)
}

@(test)
test_window_menu_invoke_rejects_unknown :: proc(t: ^testing.T) {
	_window_fixture()
	defer editor.window_chrome_shutdown()

	no_window, _ := editor.window_menu_invoke("Window Menu/Nope/Reset")
	testing.expect(t, !no_window, "an unknown window does not invoke")
	no_label, _ := editor.window_menu_invoke("Window Menu/Console/Nope")
	testing.expect(t, !no_label, "an unknown label does not invoke")
	// A main-menu path must fall through to the main menu, not be swallowed.
	not_window, _ := editor.window_menu_invoke("Edit/Undo")
	testing.expect(t, !not_window, "a path without the Window Menu prefix is not ours")
}

// The menu and the toolbar are separate registries: an item registered for one
// must not show up in the other.
@(test)
test_window_menu_and_toolbar_do_not_mix :: proc(t: ^testing.T) {
	_window_fixture()
	defer editor.window_chrome_shutdown()

	// A toolbar item is not a menu path — it draws a widget, it has no label
	// to invoke by.
	paths := editor.window_menu_paths()
	for p in paths do testing.expect(t, !strings.has_prefix(p, "Window Menu/Output/"), "a toolbar item is not a menu path")

	// And a window whose only items are menu items reserves no toolbar width.
	testing.expect_value(t, editor.window_tab_bar_width(session.window_ref_of("Console")), f32(0))
}

// The id keys the registry and the imgui ini, so it is the text after ###.
@(test)
test_window_chrome_id_is_the_ini_key :: proc(t: ^testing.T) {
	testing.expect_value(t, editor.window_id_of(icons.TITLE_CONSOLE), "Console")
	testing.expect_value(t, editor.window_id_of(icons.TITLE_PROJECT_INSPECTOR), "Project Inspector")
	// A title written without the marker still keys something stable.
	testing.expect_value(t, editor.window_id_of("Plain"), "Plain")
}

// --- User settings (libs/core/user_settings.odin) -------------------------------
//
// A per-developer preference, kept out of ProjectSettings because it is about
// the person rather than the project. A missing file must read as "defaults",
// since that is a fresh checkout and a deleted UserSettings/ alike.

@(private = "file")
_Prefs :: struct {
	flag:  bool,
	count: int,
	ratio: f32,
}

@(test)
test_user_settings_round_trip :: proc(t: ^testing.T) {
	NAME :: "Test Window"
	defer os.remove(engine.user_settings_file(NAME))

	written := _Prefs{flag = true, count = 7, ratio = 0.25}
	testing.expect(t, engine.user_settings_save(NAME, &written, typeid_of(_Prefs)), "save writes")

	read: _Prefs
	testing.expect(t, engine.user_settings_load(NAME, &read), "load reads")
	testing.expect_value(t, read, written)
}

// A missing file leaves the struct at its initializer, so a first run and a
// deleted UserSettings/ behave the same as any later run.
@(test)
test_user_settings_missing_file_keeps_defaults :: proc(t: ^testing.T) {
	defaults := _Prefs{flag = true, count = 3, ratio = 1}
	v := defaults
	testing.expect(t, !engine.user_settings_load("No Such Window At All", &v), "a missing file reports false")
	// ... and changes nothing.
	testing.expect_value(t, v, defaults)
}

// The editor writes a missing file with the defaults at startup, so every
// setting has a file to edit, and never overwrites one that exists.
@(test)
test_user_settings_create_writes_only_a_missing_file :: proc(t: ^testing.T) {
	NAME :: "Test Create Window"
	defer os.remove(core.user_settings_file(NAME))
	os.remove(core.user_settings_file(NAME))

	defaults := _Prefs{flag = true, count = 3, ratio = 1}
	testing.expect(t, core.user_settings_create(NAME, &defaults, typeid_of(_Prefs)), "create writes")
	read: _Prefs
	testing.expect(t, core.user_settings_load(NAME, &read), "the created file loads")
	testing.expect_value(t, read, defaults)

	changed := _Prefs{count = 9}
	testing.expect(t, core.user_settings_create(NAME, &changed, typeid_of(_Prefs)), "create on an existing file succeeds")
	read = {}
	testing.expect(t, core.user_settings_load(NAME, &read), "load reads")
	testing.expect_value(t, read, defaults)
}

// The name is a file slug, so it survives spaces and case the way the project
// settings files do.
@(test)
test_user_settings_file_slug :: proc(t: ^testing.T) {
	testing.expect_value(t, engine.user_settings_file("Animation"), "UserSettings/animation.json")
	testing.expect_value(t, engine.user_settings_file("Test Window"), "UserSettings/test_window.json")
}

// A window menu IS a menu tree, so a path with slashes nests instead of becoming
// a label with slashes in it. The flat list this replaced could not do it, and
// nothing in window_chrome implements nesting — it comes from the menu package.
@(test)
test_window_menu_supports_submenus :: proc(t: ^testing.T) {
	editor.window_chrome_shutdown()
	defer editor.window_chrome_shutdown()
	_window_ran = 0
	editor.window_menu_add_action("Console", "Export/As PNG", _window_act)

	paths := editor.window_menu_paths()
	testing.expect(t, _has(paths, "Window Menu/Console/Export/As PNG"), "a nested item addresses by its full path")
	// The submenu itself is a container, not something to invoke.
	testing.expect(t, !_has(paths, "Window Menu/Console/Export"), "the parent submenu is not invokable")

	ok, _ := editor.window_menu_invoke("Window Menu/Console/Export/As PNG")
	testing.expect(t, ok)
	testing.expect_value(t, _window_ran, 1)
}
