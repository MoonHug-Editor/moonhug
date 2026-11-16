package scenarios

// Joints from a scene file (plugins/physics2d/joints.odin): a link hinged to
// a static anchor by a saved reference to the anchor's Rigidbody2D swings
// about its pivot once the game runs.

import "core:encoding/json"
import "core:math"
import "core:testing"

@(private = "file")
_HINGED_SCENE :: `{
  "root": 1, "next_local_id": 30,
  "transforms": [
    {"local_id": 1, "name": "Root", "is_active": true, "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
     "parent": {"pptr": {"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}},
     "children": [{"pptr": {"local_id": 2, "guid": "00000000-0000-0000-0000-000000000000"}}, {"pptr": {"local_id": 3, "guid": "00000000-0000-0000-0000-000000000000"}}],
     "components": []},
    {"local_id": 2, "name": "Anchor", "is_active": true, "position": [-1,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
     "parent": {"pptr": {"local_id": 1, "guid": "00000000-0000-0000-0000-000000000000"}},
     "children": [], "components": [{"local_id": 10}, {"local_id": 11}]},
    {"local_id": 3, "name": "Link", "is_active": true, "position": [0.5,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
     "parent": {"pptr": {"local_id": 1, "guid": "00000000-0000-0000-0000-000000000000"}},
     "children": [], "components": [{"local_id": 20}, {"local_id": 21}, {"local_id": 22}]}
  ],
  "nested_scenes": [], "breadcrumbs": [],
  "components": [
    {"__type": "add56122-a3b9-4fcb-a924-0fa64b35d523", "base": {"enabled": true, "local_id": 10}, "body_type": 2, "gravity_scale": 1.0},
    {"__type": "1e2d0da1-9df6-4668-9f86-f76351378394", "base": {"enabled": true, "local_id": 11}, "density": 1.0, "size": [0.2, 0.2]},
    {"__type": "add56122-a3b9-4fcb-a924-0fa64b35d523", "base": {"enabled": true, "local_id": 20}, "body_type": 0, "gravity_scale": 1.0, "use_auto_mass": true},
    {"__type": "1e2d0da1-9df6-4668-9f86-f76351378394", "base": {"enabled": true, "local_id": 21}, "density": 1.0, "size": [1.0, 1.0]},
    {"__type": "4c7f2a91-3e6b-4d58-9a1f-6b2e8c0d7f13", "base": {"enabled": true, "local_id": 22}, "connected": {"local_id": 10}, "anchor": [-0.5, 0.0]}
  ]
}`

@(test)
hinge_from_a_scene_file_swings_in_play :: proc(t: ^testing.T) {
	r := begin(t)
	project_write(r, "assets/Hinge.scene", _HINGED_SCENE)
	editor_start(r)
	call(r, "open_scene", `{"path":"assets/Hinge.scene"}`)
	frames(r, 3)
	call(r, "invoke_menu", `{"path":"Edit/Play"}`)

	// The pivot is the world origin, the link's left edge: swinging, its
	// center stays 0.5 from it and goes below it.
	pos: [3]f64
	swung := false
	for _ in 0 ..< 600 {
		list, _ := at(call(r, "list_objects", `{"name":"Link","detail":true}`), "objects").(json.Array)
		if len(list) != 1 do continue
		p, _ := at(list[0], "position").(json.Array)
		if len(p) != 3 do continue
		pos = {as_f64(p[0]), as_f64(p[1]), as_f64(p[2])}
		if pos.y < -0.3 {
			swung = true
			break
		}
	}
	testing.expectf(t, swung, "the link swings down, at %v", pos)
	testing.expectf(t, abs(math.sqrt(pos.x * pos.x + pos.y * pos.y) - 0.5) < 0.03, "about the pivot its hinge names, at %v", pos)

	call(r, "invoke_menu", `{"path":"Edit/Play"}`)
	frames(r, 5)
	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	editor_quit(r)
}
