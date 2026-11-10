package scenarios

// Window scenarios: what is open, what a window saves, and what comes back
// (docs/core/Windows.md). Each is a test that starts with begin(t)
// (runner.odin).

import "core:encoding/json"
import "core:fmt"
import "core:testing"

// The open windows are saved at quit and open again at the next start: the
// default ones, one opened from a menu, and a copy under its own key.
@(test)
windows_survive_a_restart :: proc(t: ^testing.T) {
	r := begin(t)
	editor_start(r)
	for id in ([]string{"Scene", "Game", "Hierarchy", "Inspector", "Project", "Project Inspector", "Console", "Output"}) {
		testing.expectf(t, window_is_open(r, id), "a first run opens %s", id)
	}
	testing.expectf(t, !window_is_open(r, "History"), "History is closed on a first run")
	window_open(r, "History")
	copy := window_open(r, "Console", another = true)
	testing.expectf(t, copy != "" && copy != "Console", "a second Console has a key of its own, got %q", copy)
	window_close(r, "Output")

	editor_restart(r)
	testing.expectf(t, window_is_open(r, "History"), "History is open after the restart")
	testing.expectf(t, window_is_open(r, copy), "the Console copy %s is open after the restart", copy)
	testing.expectf(t, window_is_open(r, "Game"), "Game is open after the restart")
	testing.expectf(t, !window_is_open(r, "Output"), "Output stays closed after the restart")
	editor_quit(r)

	saved := at(project_json(r, "UserSettings/editor_settings.json"), "open_window_ids")
	testing.expectf(t, has_string(saved, copy) && has_string(saved, "History") && !has_string(saved, "Output"), "the settings list the open windows")
}

// A window's saved state is read at start, and written whole at quit: the
// fields the file lacks come from the window's defaults.
@(test)
saved_state_survives_a_restart :: proc(t: ^testing.T) {
	r := begin(t)
	project_write(r, "UserSettings/editor_settings.json", `{"windows":[
		{"window":"Game","state":{"size_index":4,"stats":true}},
		{"window":"Console","state":{"show_info":false,"split_ratio":0.5}}]}`)
	editor_start(r)
	// A window in a hidden tab has not drawn, so its state is the saved one.
	game := at(window_state(r, "Game"), "state")
	testing.expectf(t, as_int(at(game, "size_index")) == 4 && as_bool(at(game, "stats")), "the Game window starts with its saved state")
	editor_quit(r)

	for w in ([]string{"Game", "Console"}) {
		state := _saved_window(r, w)
		testing.expectf(t, state != nil, "the settings keep a state for %s", w)
	}
	game = _saved_window(r, "Game")
	testing.expectf(t, as_int(at(game, "size_index")) == 4 && as_bool(at(game, "stats")), "the saved fields stay")
	testing.expectf(t, as_f64(at(game, "scale")) == 1, "a field the file lacked is saved with the window's default, scale is %v", at(game, "scale"))
	console := _saved_window(r, "Console")
	testing.expectf(t, !as_bool(at(console, "show_info")) && as_bool(at(console, "show_error")), "the Console keeps show_info off and gets show_error from its defaults")
}

// A closed window comes back from Reopen Closed under its key, with its state.
@(test)
reopen_closed_brings_a_window_back :: proc(t: ^testing.T) {
	r := begin(t)
	editor_start(r)
	copy := window_open(r, "Game", another = true)
	testing.expectf(t, at(window_state(r, copy), "state") != nil, "an open Game copy has a state")
	window_close(r, copy)
	st := window_state(r, copy)
	testing.expectf(t, !as_bool(at(st, "open")), "the copy is closed")
	testing.expectf(t, as_bool(at(st, "can_reopen")), "the closed copy can come back")
	testing.expectf(t, at(st, "state") != nil, "its state waits for it")

	call(r, "run_command", `{"command":"Window/Reopen Closed"}`)
	frames(r, 2)
	st = window_state(r, copy)
	testing.expectf(t, as_bool(at(st, "open")), "Reopen Closed brings the copy back under its key")
	testing.expectf(t, at(st, "state") != nil, "with its state")
	editor_quit(r)
}

// Two Game windows render side by side, each with its own state.
@(test)
game_window_copies :: proc(t: ^testing.T) {
	r := begin(t)
	editor_start(r)
	copy := window_open(r, "Game", another = true)
	frames(r, 5)
	testing.expectf(t, window_is_open(r, "Game") && window_is_open(r, copy), "both Game windows are open")
	shot := call(r, "screenshot", `{"target":"game","max_size":16}`)
	testing.expectf(t, as_int(at(shot, "width")) > 1, "the game renders with two Game windows open")
	window_close(r, copy)
	frames(r, 5)
	shot = call(r, "screenshot", `{"target":"game","max_size":16}`)
	testing.expectf(t, as_int(at(shot, "width")) > 1, "the game renders after the copy closed")
	editor_quit(r)
}

// A locked window keeps what it shows while the selection moves on, through
// a close and Reopen Closed, and through a restart.
@(test)
lock_comes_back_with_its_window :: proc(t: ^testing.T) {
	r := begin(t)
	A :: "assets/a.txt"
	B :: "assets/b.txt"
	project_write(r, A, "a")
	project_write(r, B, "b")
	editor_start(r)
	copy := window_open(r, "Project Inspector", another = true)

	select_asset(r, A)
	call(r, "window_lock", fmt.tprintf(`{{"window":%q,"locked":true}}`, copy))
	select_asset(r, B)
	testing.expectf(t, _shows(r, copy, A), "the locked copy keeps %s while %s is selected", A, B)
	testing.expectf(t, _shows(r, "Project Inspector", B), "the unlocked window follows the selection")

	window_close(r, copy)
	testing.expectf(t, as_bool(at(window_state(r, copy), "can_reopen")), "the closed copy can come back")
	call(r, "run_command", `{"command":"Window/Reopen Closed"}`)
	frames(r, 2)
	testing.expectf(t, window_is_open(r, copy), "Reopen Closed brings the copy back")
	testing.expectf(t, _shows(r, copy, A), "locked to %s as before", A)

	editor_restart(r)
	// The locks are taken up once the reopened scenes have loaded.
	frames(r, 10)
	testing.expectf(t, window_is_open(r, copy), "the copy is open after the restart")
	testing.expectf(t, _shows(r, copy, A), "and still locked to %s", A)
	editor_quit(r)
}

// A window in a workspace frame has its lock and its saved state kept by the
// workspace: they are in the workspace's file, and they come back when the
// Workspace window is reopened and after a restart.
@(test)
framed_window_keeps_its_lock_and_state :: proc(t: ^testing.T) {
	r := begin(t)
	A :: "assets/a.txt"
	B :: "assets/b.txt"
	project_write(r, A, "a")
	project_write(r, B, "b")
	editor_start(r)
	window_open(r, "workspace")
	call(r, "workspace_new", `{"source":"Project"}`)
	inspector := as_string(at(call(r, "workspace_add", `{"id":"Project Inspector"}`), "window"))
	game := as_string(at(call(r, "workspace_add", `{"id":"Game"}`), "window"))
	frames(r, 3)
	testing.expectf(t, as_string(at(window_state(r, inspector), "host")) == "workspace", "the added Project Inspector %s is in the Workspace window", inspector)
	testing.expectf(t, as_string(at(window_state(r, game), "host")) == "workspace", "the added Game window %s is in the Workspace window", game)

	select_asset(r, A)
	call(r, "window_lock", fmt.tprintf(`{{"window":%q,"locked":true}}`, inspector))
	select_asset(r, B)
	frames(r, 3)
	testing.expectf(t, _shows(r, inspector, A), "the framed copy is locked to %s", A)

	// The workspace saves at once.
	saved := _workspace_window(r, inspector)
	testing.expectf(t, as_string(at(saved, "assets", 0, "path")) == A || as_string(at(saved, "assets", 0, "guid")) != "", "the workspace's file holds the copy's lock")
	testing.expectf(t, at(_workspace_window(r, game), "state") != nil, "the workspace's file holds the Game copy's state")

	// The Workspace window closed, then brought back.
	window_close(r, "workspace")
	frames(r, 3)
	testing.expectf(t, !window_is_open(r, inspector), "closing the Workspace window closes its windows")
	call(r, "run_command", `{"command":"Window/Reopen Closed"}`)
	frames(r, 5)
	testing.expectf(t, window_is_open(r, "workspace"), "Reopen Closed brings the Workspace window back")
	testing.expectf(t, window_is_open(r, inspector), "with its framed window")
	testing.expectf(t, _shows(r, inspector, A), "still locked to %s", A)

	editor_restart(r)
	frames(r, 10)
	testing.expectf(t, as_string(at(window_state(r, inspector), "host")) == "workspace", "after a restart the copy is in its frame")
	testing.expectf(t, _shows(r, inspector, A), "and locked to %s", A)
	testing.expectf(t, window_is_open(r, game), "the Game copy is back too")
	editor_quit(r)
}

// What the project's workspace file saves for the window `key`, nil for none.
@(private = "file")
_workspace_window :: proc(r: ^Run, key: string) -> json.Value {
	workspaces, _ := at(project_json(r, "ProjectSettings/workspaces.json"), "workspaces").(json.Array)
	for ws in workspaces {
		windows, _ := at(ws, "windows").(json.Array)
		for w in windows do if as_string(at(w, "window")) == key do return w
	}
	return nil
}

// Whether the window `key` is locked and shows exactly the asset `path`.
@(private = "file")
_shows :: proc(r: ^Run, key: string, path: string) -> bool {
	st := window_state(r, key)
	assets, _ := at(st, "assets").(json.Array)
	return len(assets) == 1 && as_string(assets[0]) == path
}

// The state the settings file keeps for the window `key`, nil for none.
@(private = "file")
_saved_window :: proc(r: ^Run, key: string) -> (state: json.Value) {
	windows, _ := at(project_json(r, "UserSettings/editor_settings.json"), "windows").(json.Array)
	for w in windows do if as_string(at(w, "window")) == key do return at(w, "state")
	return nil
}

// An edit made before Play is still unsaved after Stop: Save writes it.
@(test)
edit_before_play_is_saved_after_stop :: proc(t: ^testing.T) {
	r := begin(t)
	SCENE :: "assets/demo.scene"
	meshes :: "plugins/essentials/assets/meshes/"
	for file in ([]string{"Sphere.glb", "Sphere.glb.meta", "Cube.glb", "Cube.glb.meta"}) {
		project_copy(r, fmt.tprintf("%s%s", meshes, file), fmt.tprintf("assets/%s", file))
	}
	project_copy(r, "plugins/app/assets/demo_sub_assets/demo_sub_assets.scene", SCENE)
	// The green of the scene's Marble material, in the file.
	green :: proc(r: ^Run) -> f64 {
		records, _ := at(project_json(r, "assets/demo.scene"), "assets").(json.Array)
		for a in records do if as_string(at(a, "name")) == "Marble" do return as_f64(at(a, "data", "color", 1))
		return -1
	}
	marble := i64(0)
	{
		records, _ := at(project_json(r, SCENE), "assets").(json.Array)
		for a in records do if as_string(at(a, "name")) == "Marble" do marble = as_int(at(a, "local_id"))
	}
	editor_start(r)
	call(r, "open_scene", fmt.tprintf(`{{"path":%q}}`, SCENE))
	frames(r, 5)
	call(r, "asset_document_set", fmt.tprintf(`{{"path":%q,"sub_id":%d,"values":{{"color":[1,0,0,1]}}}}`, SCENE, marble))
	frames(r, 3)
	call(r, "invoke_menu", `{"path":"Edit/Play"}`)
	frames(r, 10)
	call(r, "invoke_menu", `{"path":"Edit/Play"}`)
	frames(r, 10)
	testing.expectf(t, green(r) == 1, "nothing is written before Save")
	call(r, "invoke_menu", `{"path":"File/Save"}`)
	frames(r, 5)
	testing.expectf(t, green(r) == 0, "Save after Stop writes the edit made before Play, green is %v", green(r))
	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	editor_quit(r)
}
