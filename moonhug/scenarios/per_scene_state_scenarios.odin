package scenarios

// What the editor keeps per scene, per developer (core.Per_Asset): the rows
// left open in the Hierarchy and where the Scene window looked. Another scene
// in between and a restart keep both. A scene gone from the project leaves
// nothing behind.

import "core:fmt"
import "core:os"
import "core:testing"

@(private = "file")
_A_GUID :: "5ce4e000-0000-4000-8000-00000000000a"
@(private = "file")
_B_GUID :: "5ce4e000-0000-4000-8000-00000000000b"

@(private = "file")
_ZERO :: `{"pptr": {"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}}`

@(private = "file")
_ref :: proc(lid: int) -> string {
	return fmt.tprintf(`{{"pptr": {{"local_id": %d, "guid": "00000000-0000-0000-0000-000000000000"}}}}`, lid)
}

@(private = "file")
_object :: proc(lid: int, name: string, parent: string, children: string) -> string {
	return fmt.tprintf(`{{"local_id": %d, "name": %q, "is_active": true, "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1, "parent": %s, "children": [%s], "components": []}}`, lid, name, parent, children)
}

// The camera saved for the scene of `guid` in UserSettings, nil when none.
@(private = "file")
_camera :: proc(r: ^Run, guid: string) -> (dist: f64, ok: bool) {
	saved := at(project_json(r, "UserSettings/scene_cameras.json"), "entries", guid)
	if saved == nil do return
	return as_f64(at(saved, "dist")), true
}

@(test)
per_scene_folds_and_camera_survive_switching_and_restart :: proc(t: ^testing.T) {
	r := begin(t)
	// A: ARoot > Parent > Kid. B: one object.
	project_write(r, "assets/A.scene", fmt.tprintf(`{{"root": 1, "next_local_id": 4, "transforms": [%s, %s, %s], "nested_scenes": [], "breadcrumbs": [], "components": []}}`,
		_object(1, "ARoot", _ZERO, _ref(2)), _object(2, "Parent", _ref(1), _ref(3)), _object(3, "Kid", _ref(2), "")))
	project_write(r, "assets/A.scene.meta", `{"guid": "` + _A_GUID + `"}`)
	project_write(r, "assets/B.scene", fmt.tprintf(`{{"root": 1, "next_local_id": 2, "transforms": [%s], "nested_scenes": [], "breadcrumbs": [], "components": []}}`, _object(1, "BRoot", _ZERO, "")))
	project_write(r, "assets/B.scene.meta", `{"guid": "` + _B_GUID + `"}`)
	editor_start(r)
	call(r, "open_scene", `{"path":"assets/A.scene"}`)
	frames(r, 5)

	// The root opens by default, Parent is closed.
	parent, listed := item_rect(r, "Hierarchy", "Parent")
	if !testing.expectf(t, listed, "the Hierarchy shows Parent under the open root") do return
	_, kid_shown := item_rect(r, "Hierarchy", "Kid")
	testing.expect(t, !kid_shown, "Kid is folded away")
	// Parent's arrow, left of its icon and name: the name starts an arrow
	// (about 23 points) and an icon (about 18) after the row's indent.
	click(r, parent.x - 30, parent.y + parent[3] / 2)
	_, kid_shown = item_rect(r, "Hierarchy", "Kid")
	if !testing.expect(t, kid_shown, "the arrow opens Parent") do return

	// The wheel over the Scene window brings the camera closer.
	scene, shown := window_rect(r, "Scene")
	if !testing.expect(t, shown, "the Scene window is open") do return
	wheel :: proc(r: ^Run, scene: [4]f64, notches: int) {
		call(r, "input", fmt.tprintf(`{{"steps":[{{"type":"move","x":%v,"y":%v}},{{"type":"wait","frames":1}},{{"type":"wheel","y":%v}},{{"type":"wait","frames":3}}]}}`, scene.x + scene[2] / 2, scene.y + scene[3] / 2, notches))
	}
	wheel(r, scene, 3)

	// B in between, then A again: Parent open as it was left. B, seen the
	// first time, keeps the view as it is, and the wheel takes it away.
	call(r, "open_scene", `{"path":"assets/B.scene"}`)
	frames(r, 5)
	wheel(r, scene, -6)
	call(r, "open_scene", `{"path":"assets/A.scene"}`)
	frames(r, 5)
	_, kid_shown = item_rect(r, "Hierarchy", "Kid")
	testing.expect(t, kid_shown, "A comes back with Parent open")
	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	editor_quit(r)

	// Saved per scene: A's open rows (the root and Parent), a camera each.
	folds := at(project_json(r, "UserSettings/hierarchy_folds.json"), "entries", _A_GUID)
	testing.expectf(t, folds != nil && as_int(at(folds, 0)) == 1 && as_int(at(folds, 1)) == 2, "A keeps its root and Parent open: %v", folds)
	a_dist, a_saved := _camera(r, _A_GUID)
	b_dist, b_saved := _camera(r, _B_GUID)
	if !testing.expect(t, a_saved && b_saved, "a camera is saved for each scene") do return
	testing.expectf(t, a_dist < b_dist, "A keeps its closer camera, B its farther one: %v against %v", a_dist, b_dist)

	// B leaves the project while the editor is closed. A restart opens A as
	// it was: a camera put back is saved unchanged.
	os.remove(project_path(r, "assets/B.scene"))
	os.remove(project_path(r, "assets/B.scene.meta"))
	editor_start(r)
	call(r, "open_scene", `{"path":"assets/A.scene"}`)
	frames(r, 5)
	_, kid_shown = item_rect(r, "Hierarchy", "Kid")
	testing.expect(t, kid_shown, "after a restart A still has Parent open")
	editor_quit(r)
	again, _ := _camera(r, _A_GUID)
	testing.expectf(t, abs(again - a_dist) < 1e-4, "after a restart A's camera is where it was left: %v, then %v", a_dist, again)
	_, b_kept := _camera(r, _B_GUID)
	testing.expect(t, !b_kept, "the camera of the scene gone is dropped")
}
