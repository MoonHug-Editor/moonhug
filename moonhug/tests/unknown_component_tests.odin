package tests

// Missing-component preservation: a record whose
// "__type" guid isn't registered in this binary must survive load → save
// VERBATIM, still attached to its transform — a binary without some package
// compiled in must never wipe that package's components from a scene.

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"
import "../engine"
import common "common"

UNKNOWN_GUID :: "deadbeef-0000-4000-8000-000000000042"

@(test)
test_unknown_component_survives_resave :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	scene_json := `{
		"root": 1,
		"next_local_id": 10,
		"transforms": [
			{"local_id": 1, "name": "Root", "is_active": true,
			 "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
			 "parent": {"pptr": {"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}},
			 "children": [], "components": [{"local_id": 5}]}
		],
		"nested_scenes": [], "breadcrumbs": [],
		"components": [
			{"__type": "` + UNKNOWN_GUID + `", "base": {"local_id": 5, "enabled": true}, "mystery_field": 42}
		]
	}`
	path :: "moonhug/tests/fixtures/_unknown_comp.scene"
	werr := os.write_entire_file(path, transmute([]byte)scene_json)
	testing.expect(t, werr == nil, "fixture write should succeed")
	defer os.remove(path)

	s := engine.scene_load_single_path(path)
	testing.expect(t, s != nil, "scene should load despite the unknown component")
	if s == nil do return
	testing.expect_value(t, len(s.unknown_components), 1)

	data, ok := engine.scene_serialize(s)
	testing.expect(t, ok, "serialize should succeed")
	if !ok do return
	defer delete(data)

	text := string(data)
	testing.expect(t, strings.contains(text, UNKNOWN_GUID), "record should re-emit with its guid")
	testing.expect(t, strings.contains(text, "mystery_field"), "record fields should survive verbatim")

	// The transform attachment survives: the root's components list references
	// the record's lid again.
	sf: engine.SceneFile
	uerr := json.unmarshal(data, &sf)
	testing.expect(t, uerr == nil, "resaved scene should parse")
	if uerr != nil do return
	defer engine.scene_file_destroy(&sf)
	attached := false
	for &tr in sf.transforms {
		for c in tr.components {
			if c.local_id == 5 do attached = true
		}
	}
	testing.expect(t, attached, "transform should still reference the preserved record")
}
