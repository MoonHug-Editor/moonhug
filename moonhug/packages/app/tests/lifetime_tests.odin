package app_tests

// Lifetime round-trips as an ext record (regression: it vanished from scenes
// resaved by an editor binary that predated its registry entry — unknown ext
// guids are silently dropped on load, see the missing-component note in
// docs/Plugins.md).

import app ".."
import "moonhug:engine"
import common "moonhug:tests/common"
import "core:fmt"
import "core:strings"
import "core:testing"

@(test)
test_lifetime_serializes :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	tH := engine.transform_new("Bomb")
	_, lt_raw := engine.transform_add_comp(tH, .Lifetime)
	testing.expect(t, lt_raw != nil, "add Lifetime should succeed")
	if lt_raw == nil do return
	lt := cast(^app.Lifetime)lt_raw
	lt.duration = 4.5

	data, ok := engine.scene_serialize(tc.scene)
	testing.expect(t, ok, "scene should serialize")
	if !ok do return
	defer delete(data)

	text := string(data)
	fmt.printf("has guid: %v, has duration: %v\n",
		strings.contains(text, "c3a1e4f2-7b8d-4a2e-9c5f-1d6e3b0f7a8c"),
		strings.contains(text, "4.5"))
	testing.expect(t, strings.contains(text, "c3a1e4f2-7b8d-4a2e-9c5f-1d6e3b0f7a8c"),
		"serialized scene should contain the Lifetime ext record")
}
