package engine_tests

// Two edges of asset files (libs/serialization): a type with no saved fields
// saves as its guid alone, and a file that fails to load leaves nothing
// allocated.

import "core:encoding/json"
import "core:encoding/uuid"
import "core:mem"
import "core:os"
import "core:testing"
import asset_pipeline "moonhug:editor/assets"
import serialization "moonhug:libs/serialization"
import "moonhug:packages/engine"
import common "moonhug:tests/common"

// Nothing of it is saved.
@(private = "file")
_Unsaved :: struct {
	cache: int `json:"-"`,
}

@(test)
test_asset_with_no_saved_fields_saves :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	path :: "moonhug/tests/fixtures/_test_unsaved_fields.asset"
	defer os.remove(path)
	guid, _ := uuid.read("6f0e1c52-4a7b-4c4e-9d1a-2b7c8e5f3a11")
	testing.expect(t, serialization.write_asset_to_path(path, guid, _Unsaved{cache = 3}), "an asset with no saved fields writes")

	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil, "the file is there")
	value, perr := json.parse(data, allocator = context.temp_allocator)
	testing.expect(t, perr == nil, "the file is JSON")
	root, is_object := value.(json.Object)
	testing.expect(t, is_object && len(root) == 1, "the object holds the type guid alone")
	if is_object {
		got, _ := root[serialization.TYPE_GUID_KEY].(json.String)
		testing.expect_value(t, got, "6f0e1c52-4a7b-4c4e-9d1a-2b7c8e5f3a11")
	}
}

@(test)
test_asset_that_fails_to_load_leaves_nothing :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// Two names read, then a number where a name belongs.
	text := `{"__type_guid": "61bc7a2f-3326-4f13-b233-7bccf12f709e", "names": ["Default", "Water", 5]}`
	_ = engine.Render_Layers{}

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		_, ok := serialization.load_from_bytes(transmute([]u8)string(text))
		testing.expect(t, !ok, "a name that is a number does not load")
	}
	testing.expect_value(t, len(track.allocation_map), 0)
}

// A file's extension finds its importer in any case: "Tree.PNG" imports as
// "tree.png" does.
@(test)
test_importer_lookup_ignores_extension_case :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	lower := asset_pipeline.importer_for_extension(".png")
	testing.expect(t, lower != "", "an importer takes .png")
	testing.expect_value(t, asset_pipeline.importer_for_extension(".PNG"), lower)
	testing.expect_value(t, asset_pipeline.importer_for_extension(".Png"), lower)
	testing.expect(t, asset_pipeline.is_importable_extension(".PNG"), ".PNG is importable")
	testing.expect(t, !asset_pipeline.is_importable_extension(".NOPE"), "an extension nothing takes")
}
