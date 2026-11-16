package scenarios

// GameObject > Create Prefab
// (plugins/engine/editor/scene_windows/prefab_create.odin): the selected
// object becomes a prefab file and an instance of it. Saved and reopened, the
// scene keeps the references: the scene's into the instance, and the
// instance's out to the scene as an override.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:testing"

@(private = "file")
_CANVAS :: "ba2db3cd-79be-4d26-9cab-be3fc317d685"

// Root > Player, Tank > Turret. Each holds a Canvas whose render_camera
// names another object: Player names Turret, Tank names Player, Turret names
// Tank.
@(private = "file")
_tank_scene :: proc() -> string {
	obj :: proc(lid: int, name: string, parent: int, children: string, comp: int) -> string {
		return fmt.tprintf(`{{"local_id": %d, "name": %q, "is_active": true, "position": [1,2,3], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
     "parent": {{"pptr": {{"local_id": %d, "guid": "00000000-0000-0000-0000-000000000000"}}}}, "children": [%s], "components": [{{"local_id": %d}}]}}`, lid, name, parent, children, comp)
	}
	child :: proc(lid: int) -> string {
		return fmt.tprintf(`{{"pptr": {{"local_id": %d, "guid": "00000000-0000-0000-0000-000000000000"}}}}`, lid)
	}
	canvas :: proc(lid, aim: int) -> string {
		return fmt.tprintf(`{{"__type": %q, "base": {{"enabled": true, "local_id": %d}}, "render_camera": {{"local_id": %d}}, "plane_distance": 100.0}}`, _CANVAS, lid, aim)
	}
	return fmt.tprintf(`{{
  "root": 1, "next_local_id": 40,
  "transforms": [
    {{"local_id": 1, "name": "Root", "is_active": true, "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
     "parent": {{"pptr": {{"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}}}}, "children": [%s, %s], "components": []}},
    %s,
    %s,
    %s
  ],
  "nested_scenes": [], "breadcrumbs": [],
  "components": [%s, %s, %s]
}}`, child(11), child(12), obj(11, "Player", 1, "", 21), obj(12, "Tank", 1, child(13), 22), obj(13, "Turret", 12, "", 23), canvas(21, 13), canvas(22, 11), canvas(23, 12))
}

@(private = "file")
_aim :: proc(r: ^Run, name: string) -> i64 {
	v := call(r, "get_property", fmt.tprintf(`{{"name":%q,"component":"Canvas","path":"render_camera"}}`, name))
	return as_int(at(v, "value", "local_id"))
}

@(private = "file")
_lid :: proc(r: ^Run, name: string) -> i64 {
	list, _ := at(call(r, "list_objects", fmt.tprintf(`{{"name":%q}}`, name)), "objects").(json.Array)
	if len(list) != 1 do return -1
	return as_int(at(list[0], "local_id"))
}

@(test)
create_prefab_keeps_references_through_save :: proc(t: ^testing.T) {
	r := begin(t)
	project_write(r, "assets/Main.scene", _tank_scene())
	editor_start(r)
	call(r, "open_scene", `{"path":"assets/Main.scene"}`)
	// The Project window shows the folder the prefab goes in.
	call(r, "ping_asset", `{"path":"assets/Main.scene"}`)
	call(r, "select", `{"name":"Tank"}`)
	frames(r, 3)

	res, code, msg := call_raw(r, "invoke_menu", `{"path":"GameObject/Create Prefab"}`)
	if !testing.expectf(t, code == "" && as_bool(at(res, "invoked")), "Create Prefab runs: %s %s", code, msg) do return
	frames(r, 3)
	testing.expectf(t, os.exists(project_path(r, "assets/Tank.scene")), "the prefab is written next to the scene")

	turret := _lid(r, "Turret")
	player := _lid(r, "Player")
	testing.expectf(t, turret != 13 && turret > 0, "Turret is the instance's object now, %v", turret)
	testing.expectf(t, _aim(r, "Player") == turret, "Player names the instance's Turret")
	testing.expectf(t, _aim(r, "Tank") == player, "the instance names Player")

	call(r, "invoke_menu", `{"path":"File/Save"}`)
	frames(r, 3)
	records, _ := at(project_json(r, "assets/Main.scene"), "nested_scenes").(json.Array)
	if testing.expectf(t, len(records) == 1, "the scene holds the instance, %v records", len(records)) {
		overrides, _ := at(records[0], "overrides").(json.Array)
		kept := false
		// Saved field by field: the reference's own id.
		for ov in overrides {
			switch as_string(at(ov, "property_path")) {
			case "render_camera":          kept ||= as_int(at(ov, "value", "local_id")) == player
			case "render_camera.local_id": kept ||= as_int(at(ov, "value")) == player
			}
		}
		testing.expectf(t, kept, "the reference to Player is an override of the instance: %v", overrides)
	}

	// Reopened, both references hold.
	editor_restart(r)
	call(r, "open_scene", `{"path":"assets/Main.scene"}`)
	frames(r, 3)
	testing.expectf(t, _aim(r, "Player") == _lid(r, "Turret"), "Player still names the instance's Turret")
	testing.expectf(t, _aim(r, "Tank") == _lid(r, "Player"), "the instance still names Player")
	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	editor_quit(r)
}
