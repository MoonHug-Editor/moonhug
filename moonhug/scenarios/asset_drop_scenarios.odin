package scenarios

// Dragging assets from the Project window into the scene
// (plugins/engine/editor/scene_tools/asset_drop.odin): into the Scene window
// a prefab becomes an instance on the grid under the pointer, into the
// Hierarchy a model becomes its node hierarchy.

import "core:encoding/json"
import "core:fmt"
import "core:testing"

@(private = "file")
_objects :: proc(r: ^Run, params: string) -> json.Array {
	list, _ := at(call(r, "list_objects", params), "objects").(json.Array)
	return list
}

@(test)
assets_dragged_into_the_scene_become_objects :: proc(t: ^testing.T) {
	r := begin(t)
	meshes :: "plugins/essentials/assets/meshes/"
	project_copy(r, meshes + "Cube.glb", "assets/Cube.glb")
	project_copy(r, meshes + "Cube.glb.meta", "assets/Cube.glb.meta")
	for name in ([]string{"Crate", "Main"}) {
		project_write(r, fmt.tprintf("assets/%s.scene", name), fmt.tprintf(`{{
  "root": 1, "next_local_id": 5,
  "transforms": [{{
    "local_id": 1, "name": %q, "is_active": true,
    "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
    "parent": {{"pptr": {{"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}}}},
    "children": [], "components": []
  }}],
  "nested_scenes": [], "breadcrumbs": [], "components": []
}}`, name))
	}
	editor_start(r)
	call(r, "open_scene", `{"path":"assets/Main.scene"}`)
	frames(r, 5)
	call(r, "ping_asset", `{"path":"assets/Crate.scene"}`)
	frames(r, 3)

	// The prefab into the Scene window: an instance, on the grid, since the
	// pointer meets no object there.
	row, listed := item_rect(r, "Project", "Crate.scene")
	if !testing.expectf(t, listed, "the Project window lists Crate.scene") do return
	scene, shown := window_rect(r, "Scene")
	if !testing.expectf(t, shown, "the Scene window is open") do return
	drag_mouse(r, row.x + 20, row.y + row[3] / 2, scene.x + scene[2] / 2, scene.y + scene[3] / 2)
	crates := _objects(r, `{"name":"Crate","detail":true}`)
	if !testing.expectf(t, len(crates) == 1, "the drop made one Crate, got %v", len(crates)) do return
	pos, _ := at(crates[0], "position").(json.Array)
	testing.expectf(t, len(pos) == 3 && abs(as_f64(pos[1])) < 0.01, "on the XZ grid, at %v", pos)

	// The model into the Hierarchy's empty space: its node hierarchy, the
	// mesh node drawing its part.
	call(r, "ping_asset", `{"path":"assets/Cube.glb"}`)
	frames(r, 3)
	model, mlisted := item_rect(r, "Project", "Cube.glb")
	if !testing.expectf(t, mlisted, "the Project window lists Cube.glb") do return
	hier, hshown := window_rect(r, "Hierarchy")
	if !testing.expectf(t, hshown, "the Hierarchy is open") do return
	drag_mouse(r, model.x + 20, model.y + model[3] / 2, hier.x + hier[2] / 2, hier.y + hier[3] - 20)
	drawn := _objects(r, `{"component":"MeshFilter"}`)
	testing.expectf(t, len(drawn) >= 1, "the model's mesh node draws its part, %v MeshFilters", len(drawn))

	// Saved, the scene file holds the instance as a nested scene record.
	call(r, "invoke_menu", `{"path":"File/Save"}`)
	frames(r, 3)
	records, _ := at(project_json(r, "assets/Main.scene"), "nested_scenes").(json.Array)
	testing.expectf(t, len(records) == 1, "the saved scene holds the instance, %v records", len(records))

	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	editor_quit(r)
}
