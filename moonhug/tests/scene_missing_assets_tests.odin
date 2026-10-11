package tests

// engine.scene_missing_assets: every guid in a scene file that is not a type
// guid and does not resolve, with the object, component and field holding it.

import "core:encoding/uuid"
import "core:strings"
import "core:testing"
import "moonhug:packages/engine"

@(private = "file")
_KNOWN :: "11111111-2222-4333-8444-555555555555"

@(private = "file")
_known_only :: proc(guid: uuid.Identifier) -> bool {
	known, _ := uuid.read(_KNOWN)
	return guid == known
}

@(test)
test_scene_missing_assets_names_the_holder :: proc(t: ^testing.T) {
	camera := uuid.to_string(engine.get_guid_by_typeid(engine.Camera), context.temp_allocator)
	scene := `{
		"root": 1,
		"transforms": [
			{"local_id": 1, "name": "Hero", "components": [{"local_id": 7}]}
		],
		"components": [
			{"__type": "` + "CAMERA" + `", "base": {"enabled": true, "local_id": 7},
			 "mesh": "99999999-aaaa-4bbb-8ccc-dddddddddddd",
			 "materials": ["` + _KNOWN + `", "88888888-aaaa-4bbb-8ccc-dddddddddddd"],
			 "parent": {"pptr": {"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}},
			 "source_prefab": {"pptr": {"local_id": 0, "guid": "77777777-aaaa-4bbb-8ccc-dddddddddddd"}},
			 "name": "not a guid"}
		]
	}`
	text, _ := strings.replace(scene, "CAMERA", camera, 1, context.temp_allocator)
	missing := engine.scene_missing_assets(transmute([]byte)text, _known_only)
	if !testing.expect_value(t, len(missing), 3) do return
	found := map[string]engine.Missing_Asset_Ref{}
	defer delete(found)
	for m in missing do found[m.guid] = m
	mesh := found["99999999-aaaa-4bbb-8ccc-dddddddddddd"]
	testing.expect_value(t, mesh.object, "Hero")
	testing.expect_value(t, mesh.component, "Camera")
	testing.expect_value(t, mesh.field, "mesh")
	testing.expect_value(t, found["88888888-aaaa-4bbb-8ccc-dddddddddddd"].field, "materials")
	// A {pptr: {guid}} reference keeps the field it belongs to.
	testing.expect_value(t, found["77777777-aaaa-4bbb-8ccc-dddddddddddd"].field, "source_prefab")
}

