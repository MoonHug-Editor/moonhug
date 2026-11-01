package animation_tests

// The rule that combines a clip's transform rows (clip_trs.odin): property
// identity (animation_channel_same_property, animation_clip_property_channels),
// the invariant a loaded clip holds (animation_clip_validate, refused by
// animation_clip_load), and one pose from the direct apply and the graph leaf.

import "base:runtime"
import "core:encoding/uuid"
import "core:log"
import "core:math/linalg"
import "core:os"
import "core:strings"
import "core:testing"
import asset_pipeline "moonhug:editor/assets"
import "moonhug:packages/engine"
import anim "moonhug:packages/animation"
import animation_editor "moonhug:packages/animation/editor"
import common "moonhug:tests/common"

// Appends a one-key row on `target` holding `value`, heap allocated so
// anim.cleanup_AnimationClip frees it. A property row of `field` on a Light
// when `field` is set, else a transform row on `path`. `off` is its lane mask.
@(private = "file")
_trs_row :: proc(clip: ^anim.AnimationClip, target: string, path: anim.Animation_Path, value: [4]f32, off: anim.Channel_Lanes_Off = {}, field := "") {
	ch := anim.Animation_Channel{target = strings.clone(target), path = path, lanes_off = off}
	if field != "" {
		ch.component = strings.clone(uuid.to_string(engine.get_guid_by_typeid(engine.Light), context.temp_allocator))
		ch.field = strings.clone(field)
	}
	ch.times = make([dynamic]f32)
	ch.values = make([dynamic][4]f32)
	append(&ch.times, 0)
	append(&ch.values.([dynamic][4]f32), value)
	append(&clip.channels, ch)
}

@(private = "file")
_trs_clip :: proc() -> anim.AnimationClip {
	clip := anim.AnimationClip{length = 1}
	clip.channels = make([dynamic]anim.Animation_Channel)
	return clip
}

// --- Validation ---------------------------------------------------------------------------

// Two Position rows on one target that both animate x fail, and the message
// names the lane, the property and the target.
@(test)
test_clip_validate_overlapping_lanes_fail :: proc(t: ^testing.T) {
	clip := _trs_clip()
	defer anim.cleanup_AnimationClip(&clip)
	_trs_row(&clip, "Arm", .Position, {1, 0, 0, 0}, off = {1, 2}) // x
	_trs_row(&clip, "Arm", .Position, {2, 3, 0, 0}, off = {2})    // x and y

	msg, ok := anim.animation_clip_validate(&clip)
	testing.expect(t, !ok, "two rows on lane x fail")
	testing.expectf(t, strings.contains(msg, "lane x ") && strings.contains(msg, "Position") && strings.contains(msg, "Arm"), "the message names the lane, got %q", msg)
	testing.expectf(t, !strings.contains(msg, "lane x y"), "only the shared lane is named, got %q", msg)
}

// Disjoint masks on one property pass, and so do a Rotation row and an Euler
// row on one target, and the same property on two targets.
@(test)
test_clip_validate_disjoint_lanes_and_rotation_forms_pass :: proc(t: ^testing.T) {
	clip := _trs_clip()
	defer anim.cleanup_AnimationClip(&clip)
	_trs_row(&clip, "Arm", .Position, {1, 0, 0, 0}, off = {1, 2}) // x
	_trs_row(&clip, "Arm", .Position, {0, 2, 3, 0}, off = {0})    // y and z
	_trs_row(&clip, "Arm", .Rotation, {0, 0, 0, 1})
	_trs_row(&clip, "Arm", .Euler, {0, 30, 0, 0}, off = {0, 2})
	_trs_row(&clip, "Leg", .Position, {1, 2, 3, 0})

	msg, ok := anim.animation_clip_validate(&clip)
	testing.expectf(t, ok, "the clip is valid, got %q", msg)
	testing.expect_value(t, msg, "")
}

// Two rows on one float field have no mask (width 0): they always share the
// field's one value and fail.
@(test)
test_clip_validate_two_unmasked_property_rows_fail :: proc(t: ^testing.T) {
	clip := _trs_clip()
	defer anim.cleanup_AnimationClip(&clip)
	_trs_row(&clip, "Lamp", .Position, {1, 0, 0, 0}, field = "intensity")
	_trs_row(&clip, "Lamp", .Position, {2, 0, 0, 0}, field = "intensity")
	testing.expect_value(t, anim.animation_channel_mask_width(&clip.channels[0]), 0)

	msg, ok := anim.animation_clip_validate(&clip)
	testing.expect(t, !ok, "two rows on one float field fail")
	testing.expectf(t, strings.contains(msg, "intensity") && strings.contains(msg, "Lamp"), "the message names the field and the target, got %q", msg)
}

// --- Property identity --------------------------------------------------------------------

// Channels group by target and property: the split Position rows of Arm are
// one property, Rotation and Euler are two, Leg's Position is its own, and two
// fields of one component are two.
@(test)
test_clip_property_channels_group_by_target_and_field :: proc(t: ^testing.T) {
	clip := _trs_clip()
	defer anim.cleanup_AnimationClip(&clip)
	_trs_row(&clip, "Arm", .Position, {1, 0, 0, 0}, off = {1, 2})   // 0
	_trs_row(&clip, "Arm", .Rotation, {0, 0, 0, 1})                 // 1
	_trs_row(&clip, "Arm", .Euler, {0, 30, 0, 0})                   // 2
	_trs_row(&clip, "Leg", .Position, {1, 2, 3, 0})                 // 3
	_trs_row(&clip, "Arm", .Position, {0, 0, 3, 0}, off = {0, 1})   // 4
	_trs_row(&clip, "Arm", .Position, {1, 0, 0, 0}, field = "intensity") // 5
	_trs_row(&clip, "Arm", .Position, {4, 0, 0, 0}, field = "range")     // 6

	expect_group :: proc(t: ^testing.T, clip: ^anim.AnimationClip, ch: int, want: []int, loc := #caller_location) {
		got := anim.animation_clip_property_channels(clip, ch, context.temp_allocator)
		if !testing.expectf(t, len(got) == len(want), "channel %d: %v, want %v", ch, got, want, loc = loc) do return
		for i in 0 ..< len(want) do testing.expectf(t, got[i] == want[i], "channel %d: %v, want %v", ch, got, want, loc = loc)
	}
	expect_group(t, &clip, 0, {0, 4})
	expect_group(t, &clip, 4, {0, 4})
	expect_group(t, &clip, 1, {1})
	expect_group(t, &clip, 2, {2})
	expect_group(t, &clip, 3, {3})
	expect_group(t, &clip, 5, {5})
	expect_group(t, &clip, 6, {6})

	c := clip.channels[:]
	testing.expect(t, anim.animation_channel_same_property(&c[0], &c[4]), "split Position rows are one property")
	testing.expect(t, !anim.animation_channel_same_property(&c[1], &c[2]), "Rotation and Euler are two properties")
	testing.expect(t, !anim.animation_channel_same_property(&c[0], &c[3]), "Position on two targets are two properties")
	testing.expect(t, !anim.animation_channel_same_property(&c[0], &c[5]), "a field row is not the Position row")
	testing.expect(t, !anim.animation_channel_same_property(&c[5], &c[6]), "two fields are two properties")
}

// --- One pose from both write paths -------------------------------------------------------

// On the animated object: an Euler row masked to y, a Rotation row, and a
// Position row split into an x channel and a z channel.
@(private = "file")
_trs_mixed_clip :: proc(rot: [4]f32) -> anim.AnimationClip {
	clip := _trs_clip()
	_trs_row(&clip, "", .Euler, {0, 40, 0, 0}, off = {0, 2})
	_trs_row(&clip, "", .Rotation, rot)
	_trs_row(&clip, "", .Position, {3, 0, 0, 0}, off = {1, 2})
	_trs_row(&clip, "", .Position, {0, 0, 5, 0}, off = {0, 1})
	return clip
}

// The direct apply and a graph leaf give the same pose: x and z from the
// split rows, y keeps the transform's 7, and the rotation is the Rotation
// row's angles with y from the Euler row.
@(test)
test_clip_trs_direct_apply_and_graph_leaf_agree :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()

	rot := anim.animation_quat_from_euler({30, 10, -20})
	own := anim.animation_quat_from_euler({5, 15, 25})
	e := engine.quat_to_euler_xyz(rot)
	e.y = 40
	want_rot := anim.animation_quat_from_euler(e)
	w := engine.ctx_world()

	direct := engine.transform_new("Direct")
	da := engine.pool_get(&w.transforms, engine.Handle(direct))
	da.position = {7, 7, 7}
	da.rotation = own
	clip := _trs_mixed_clip(rot)
	defer anim.cleanup_AnimationClip(&clip)
	anim.animation_clip_apply(&clip, direct, 0)
	da = engine.pool_get(&w.transforms, engine.Handle(direct))

	graph := engine.transform_new("Graph")
	ga := engine.pool_get(&w.transforms, engine.Handle(graph))
	ga.position = {7, 7, 7}
	ga.rotation = own
	g: anim.Playable_Graph
	anim.playable_graph_init(&g)
	defer anim.playable_graph_destroy(&g)
	b: anim.Animation_Binding
	anim.animation_binding_init(&b, graph)
	defer anim.animation_binding_destroy(&b)
	ref := engine.PPtr{guid = _clip_guid(0xC1)}
	anim.animation_clip_cache[ref] = _trs_mixed_clip(rot) // the cache owns it from here
	mixer := anim.playable_add(&g, anim.Playable_Mixer{})
	node := anim.playable_add(&g, anim.Playable_Clip{clip = ref})
	anim.playable_connect(&g, mixer, node, 1)
	anim.animation_pose_apply(&b, anim.playable_graph_evaluate(&g, mixer, &b))
	ga = engine.pool_get(&w.transforms, engine.Handle(graph))

	testing.expectf(t, _trs_near3(da.position, {3, 7, 5}), "the direct apply writes x and z, got %v", da.position)
	testing.expectf(t, _trs_near3(ga.position, {3, 7, 5}), "the graph writes x and z, got %v", ga.position)
	testing.expectf(t, abs(linalg.dot(da.rotation, want_rot)) > 1 - 1e-4, "the direct apply rotation, got %v want %v", da.rotation, want_rot)
	testing.expectf(t, abs(linalg.dot(ga.rotation, want_rot)) > 1 - 1e-4, "the graph rotation, got %v want %v", ga.rotation, want_rot)
	testing.expectf(t, abs(linalg.dot(da.rotation, ga.rotation)) > 1 - 1e-4, "both paths agree: %v vs %v", da.rotation, ga.rotation)
}

// With no Rotation row, an Euler row masked to y gives the base angles with
// y replaced, and the rotation is that as a quaternion.
@(test)
test_clip_trs_euler_replaces_only_its_lanes :: proc(t: ^testing.T) {
	clip := _trs_clip()
	defer anim.cleanup_AnimationClip(&clip)
	_trs_row(&clip, "", .Euler, {70, 40, -60, 0}, off = {0, 2})

	trs: anim.Clip_TRS
	anim.animation_trs_add(&trs, &clip.channels[0], 0)
	testing.expect(t, anim.animation_trs_has_rotation(trs), "an Euler row says something about the rotation")
	base := anim.animation_quat_from_euler({5, 15, 25})
	want := engine.quat_to_euler_xyz(base)
	want.y = 40
	got := anim.animation_trs_euler(trs, base)
	testing.expectf(t, _trs_near3(got, want), "the base angles with y replaced: got %v want %v", got, want)
	q := anim.animation_trs_rotation(trs, base)
	testing.expect(t, abs(linalg.dot(q, anim.animation_quat_from_euler(want))) > 1 - 1e-4, "the rotation is those angles")
}

@(private = "file")
_trs_near3 :: proc(a, b: [3]f32) -> bool {
	return abs(a.x - b.x) < 1e-3 && abs(a.y - b.y) < 1e-3 && abs(a.z - b.z) < 1e-3
}

// --- Load refusal -------------------------------------------------------------------------

@(private = "file")
_LOAD_DIR :: "moonhug/tests/fixtures/_clip_validate_tmp"

// Two Position rows on Arm, both animating x.
@(private = "file")
_BAD_CLIP :: `{
  "__type_guid": "0a4f3b1c-8e57-4c2d-9b6a-5d1e7f2c8a90",
  "length": 1.0,
  "channels": [
    {"target": "Arm", "path": 0, "times": [0], "values": [[1, 0, 0, 0]], "lanes": [true, false, false]},
    {"target": "Arm", "path": 0, "times": [0], "values": [[2, 0, 0, 0]], "lanes": [true, true, false]}
  ]
}`

// The same rows with disjoint lanes: x, then y.
@(private = "file")
_GOOD_CLIP :: `{
  "__type_guid": "0a4f3b1c-8e57-4c2d-9b6a-5d1e7f2c8a90",
  "length": 1.0,
  "channels": [
    {"target": "Arm", "path": 0, "times": [0], "values": [[1, 0, 0, 0]], "lanes": [true, false, false]},
    {"target": "Arm", "path": 0, "times": [0], "values": [[0, 2, 0, 0]], "lanes": [false, true, false]}
  ]
}`

// A clip file where two rows animate one lane does not load, and the same
// file with disjoint lanes does.
@(test)
test_clip_load_refuses_an_invalid_clip :: proc(t: ^testing.T) {
	// The clip loader pins the default allocator, and a refused file reimports
	// under it, touching the asset index: the whole test runs under default so
	// nothing is allocated under one allocator and freed under another.
	context.allocator = runtime.default_allocator()
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	os.make_directory(_LOAD_DIR)
	bad :: _LOAD_DIR + "/Bad.anim"
	good :: _LOAD_DIR + "/Good.anim"
	testing.expect(t, os.write_entire_file(bad, transmute([]u8)string(_BAD_CLIP)) == nil, "the bad clip is written")
	testing.expect(t, os.write_entire_file(good, transmute([]u8)string(_GOOD_CLIP)) == nil, "the good clip is written")
	// The .anim importer is an editor phase the test bootstrap does not run.
	animation_editor.animation_importers_init()
	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init(_LOAD_DIR)
	defer {
		engine.asset_db_shutdown()
		common.remove_tree(_LOAD_DIR)
		common.remove_tree(engine.library_dir())
	}
	testing.expect(t, asset_pipeline.asset_pipeline_import_asset(bad), "the bad clip imports, the importer does not validate")
	testing.expect(t, asset_pipeline.asset_pipeline_import_asset(good), "the good clip imports")
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()

	bad_guid, bok := engine.asset_db_get_guid(bad)
	good_guid, gok := engine.asset_db_get_guid(good)
	if !testing.expect(t, bok && gok, "both clips are registered") do return

	// The refusal logs an error, which would fail the test: it is captured.
	refused := false
	{
		context.logger = log.Logger{procedure = _capture_log, data = &refused, lowest_level = .Error}
		_, lok := anim.animation_clip_load({guid = engine.Asset_GUID(bad_guid)})
		testing.expect(t, !lok, "a clip with two rows on one lane does not load")
	}
	testing.expect(t, refused, "the refusal names the lane")
	clip, ok := anim.animation_clip_load({guid = engine.Asset_GUID(good_guid)})
	testing.expect(t, ok && clip != nil, "the valid clip loads")
	if ok do testing.expect_value(t, len(clip.channels), 2)
}

// Sets the bool at `data` when a message names the refused lane.
@(private = "file")
_capture_log :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
	if strings.contains(text, "two rows animate lane x of Position on Arm") do (cast(^bool)data)^ = true
}
