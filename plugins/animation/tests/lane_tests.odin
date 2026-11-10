package animation_tests

// Lane masks (clip.odin Animation_Channel.lanes_off, clip_property.odin "Lane
// masks"): a vector row animates only the lanes it enables. The other lanes
// keep the field's own value in every write path (the direct apply, the
// playable graph, the inspector's driven value), the mixer blends each lane
// over the clips that animate it, the file holds `lanes` only for a row with
// a disabled lane, and the Animation window removes a row with its last lane.

import "core:encoding/json"
import "core:encoding/uuid"
import "core:os"
import "core:strings"
import "core:testing"
import asset_pipeline "moonhug:editor/assets"
import "moonhug:editor/inspector"
import undo "moonhug:editor/undo"
import "moonhug:packages/engine"
import anim "moonhug:packages/animation"
import animation_editor "moonhug:packages/animation/editor"
import common "moonhug:tests/common"

// --- Runtime ------------------------------------------------------------------------------

@(private = "file")
_volume_guid_str :: proc() -> string {
	return uuid.to_string(engine.get_guid_by_typeid(engine.Volume), context.temp_allocator)
}

// Appends a one-key row holding `value`: a Volume.size row when `field` is
// set, else a transform row on `path`. `off` is its lane mask.
@(private = "file")
_lane_row :: proc(clip: ^anim.AnimationClip, path: anim.Animation_Path, field: string, value: [4]f32, off: anim.Channel_Lanes_Off) {
	ch := anim.Animation_Channel{path = path, lanes_off = off}
	if field != "" {
		ch.component = strings.clone(_volume_guid_str())
		ch.field = strings.clone(field)
	}
	ch.times = make([dynamic]f32)
	ch.values = make([dynamic][4]f32)
	append(&ch.times, 0)
	append(&ch.values.([dynamic][4]f32), value)
	append(&clip.channels, ch)
}

@(private = "file")
_lane_clip :: proc() -> anim.AnimationClip {
	clip := anim.AnimationClip{length = 1, wrap = .Loop}
	clip.channels = make([dynamic]anim.Animation_Channel)
	return clip
}

@(private = "file")
_Lane_Test :: struct {
	tc:     ^common.TestCtx,
	owner:  engine.Transform_Handle,
	volume: ^engine.Volume,
	g:      anim.Playable_Graph,
	b:      anim.Animation_Binding,
}

@(private = "file")
_lane_setup :: proc(lt: ^_Lane_Test) {
	lt.tc = new(common.TestCtx)
	common.setup(lt.tc)
	context.user_ptr = &lt.tc.uc
	anim.animation_clip_cache_init()
	lt.owner = engine.transform_new("Rig")
	_, raw := engine.transform_add_comp(lt.owner, .Volume)
	lt.volume = cast(^engine.Volume)raw
	lt.volume.size = {1, 2, 3}
	anim.playable_graph_init(&lt.g)
	anim.animation_binding_init(&lt.b, lt.owner)
}

@(private = "file")
_lane_teardown :: proc(lt: ^_Lane_Test) {
	anim.animation_binding_destroy(&lt.b)
	anim.playable_graph_destroy(&lt.g)
	anim.animation_clip_cache_shutdown()
	common.teardown(lt.tc)
	free(lt.tc)
}

@(private = "file")
_near3 :: proc(a, b: [3]f32) -> bool {
	return abs(a.x - b.x) < 1e-4 && abs(a.y - b.y) < 1e-4 && abs(a.z - b.z) < 1e-4
}

// A [3]f32 row with only y enabled writes y and leaves x and z as the field
// holds them: the direct apply, the graph at full weight, the graph after an
// edit of x (the current value, not the bind-time one), and at half weight.
@(test)
test_lane_masked_row_writes_only_enabled_lanes :: proc(t: ^testing.T) {
	lt: _Lane_Test
	_lane_setup(&lt)
	context.user_ptr = &lt.tc.uc
	defer _lane_teardown(&lt)

	clip := _lane_clip()
	_lane_row(&clip, .Position, "size", {10, 20, 30, 0}, {0, 2})
	anim.animation_clip_apply(&clip, lt.owner, 0)
	testing.expect_value(t, lt.volume.size, [3]f32{1, 20, 3})

	ref := engine.PPtr{guid = _clip_guid(0xB1)}
	anim.animation_clip_cache[ref] = clip // the cache owns it from here
	lt.volume.size = {1, 2, 3}
	mixer := anim.playable_add(&lt.g, anim.Playable_Mixer{})
	node := anim.playable_add(&lt.g, anim.Playable_Clip{clip = ref})
	anim.playable_connect(&lt.g, mixer, node, 1)

	anim.animation_pose_apply(&lt.b, anim.playable_graph_evaluate(&lt.g, mixer, &lt.b))
	testing.expect(t, _near3(lt.volume.size, {1, 20, 3}), "the graph writes y only")

	lt.volume.size.x = 7
	anim.animation_pose_apply(&lt.b, anim.playable_graph_evaluate(&lt.g, mixer, &lt.b))
	testing.expect(t, _near3(lt.volume.size, {7, 20, 3}), "an edit of a disabled lane holds")

	// Half weight: y blends with its bind-time default 2, x and z still hold.
	anim.playable_set_input_weight(&lt.g, mixer, node, 0.5)
	anim.animation_pose_apply(&lt.b, anim.playable_graph_evaluate(&lt.g, mixer, &lt.b))
	testing.expect(t, _near3(lt.volume.size, {7, 11, 3}), "half weight blends y alone")

	anim.animation_binding_write_defaults(&lt.b)
	testing.expect(t, _near3(lt.volume.size, {7, 2, 3}), "the restore writes y alone")
}

// Two clips at 0.5, one animating x and the other y of the same fields: each
// lane takes its own clip's full value, z keeps the field's value. Covers a
// property field and a transform position.
@(test)
test_lane_mixer_blends_each_lane_on_its_own :: proc(t: ^testing.T) {
	lt: _Lane_Test
	_lane_setup(&lt)
	context.user_ptr = &lt.tc.uc
	defer _lane_teardown(&lt)

	w := engine.ctx_world()
	tr := engine.pool_get(&w.transforms, engine.Handle(lt.owner))
	tr.position = {0.5, 0.5, 0.5}

	a := _lane_clip()
	_lane_row(&a, .Position, "size", {10, 0, 0, 0}, {1, 2})
	_lane_row(&a, .Position, "", {4, 0, 0, 0}, {1, 2})
	b := _lane_clip()
	_lane_row(&b, .Position, "size", {0, 20, 0, 0}, {0, 2})
	_lane_row(&b, .Position, "", {0, 6, 0, 0}, {0, 2})
	a_ref, b_ref := engine.PPtr{guid = _clip_guid(0xB2)}, engine.PPtr{guid = _clip_guid(0xB3)}
	anim.animation_clip_cache[a_ref] = a
	anim.animation_clip_cache[b_ref] = b

	mixer := anim.playable_add(&lt.g, anim.Playable_Mixer{})
	anim.playable_connect(&lt.g, mixer, anim.playable_add(&lt.g, anim.Playable_Clip{clip = a_ref}), 0.5)
	anim.playable_connect(&lt.g, mixer, anim.playable_add(&lt.g, anim.Playable_Clip{clip = b_ref}), 0.5)
	anim.animation_pose_apply(&lt.b, anim.playable_graph_evaluate(&lt.g, mixer, &lt.b))

	testing.expect(t, _near3(lt.volume.size, {10, 20, 3}), "each size lane takes its own clip's value")
	testing.expect(t, _near3(tr.position, {4, 6, 0.5}), "each position lane takes its own clip's value")
}

// One clip with a split position row (one channel per lane, the form Split
// Lanes writes): the graph merges the channels per lane, so each lane takes
// its own channel's value instead of the last channel overwriting the rest.
@(test)
test_lane_mixer_merges_split_channels_of_one_clip :: proc(t: ^testing.T) {
	lt: _Lane_Test
	_lane_setup(&lt)
	context.user_ptr = &lt.tc.uc
	defer _lane_teardown(&lt)

	w := engine.ctx_world()
	tr := engine.pool_get(&w.transforms, engine.Handle(lt.owner))
	tr.position = {0.5, 0.5, 0.5}

	a := _lane_clip()
	_lane_row(&a, .Position, "", {4, 0, 0, 0}, {1, 2})
	_lane_row(&a, .Position, "", {0, 6, 0, 0}, {0, 2})
	_lane_row(&a, .Position, "", {0, 0, 8, 0}, {0, 1})
	_lane_row(&a, .Position, "size", {10, 0, 0, 0}, {1, 2})
	_lane_row(&a, .Position, "size", {0, 20, 0, 0}, {0, 2})
	ref := engine.PPtr{guid = _clip_guid(0xB4)}
	anim.animation_clip_cache[ref] = a

	mixer := anim.playable_add(&lt.g, anim.Playable_Mixer{})
	anim.playable_connect(&lt.g, mixer, anim.playable_add(&lt.g, anim.Playable_Clip{clip = ref}), 1)
	anim.animation_pose_apply(&lt.b, anim.playable_graph_evaluate(&lt.g, mixer, &lt.b))

	testing.expect(t, _near3(tr.position, {4, 6, 8}), "each position lane takes its own channel's value")
	testing.expect(t, _near3(lt.volume.size, {10, 20, 3}), "each size lane takes its own channel's value, z keeps the field's")
}

// --- Format -------------------------------------------------------------------------------

// The `lanes` object of channel 0 in marshaled clip bytes, and whether it is
// there.
@(private = "file")
_lanes_json :: proc(t: ^testing.T, data: []byte) -> (json.Array, bool) {
	root, err := json.parse(data, .JSON, true, context.temp_allocator)
	testing.expect(t, err == nil, "the marshaled clip parses")
	obj := root.(json.Object)["channels"].(json.Array)[0].(json.Object)
	v, has := obj["lanes"]
	if !has do return nil, false
	return v.(json.Array), true
}

// A row with no `lanes` (a file without the key) has every lane enabled
// and writes back without the key.
@(test)
test_lane_missing_key_loads_all_enabled :: proc(t: ^testing.T) {
	src := `{"length": 1.0, "channels": [{"target": "", "path": 0, "times": [0.0], "values": [[1, 2, 3, 0]]}]}`
	clip: anim.AnimationClip
	err := json.unmarshal(transmute([]byte)src, &clip, .JSON, context.allocator)
	defer anim.type_cleanup_AnimationClip(&clip)
	testing.expect(t, err == nil, "the clip unmarshals")
	if len(clip.channels) != 1 do return
	ch := &clip.channels[0]
	testing.expect_value(t, ch.lanes_off, anim.Channel_Lanes_Off{})
	for l in 0 ..< 3 do testing.expect(t, anim.animation_channel_lane_on(ch, .Vec3, l), "every lane is on")

	data, merr := json.marshal(clip, {spec = .JSON}, context.temp_allocator)
	testing.expect(t, merr == nil, "the clip marshals")
	_, has := _lanes_json(t, data)
	testing.expect(t, !has, "a row with every lane enabled writes no lanes")
}

// A partial mask round-trips: `lanes` reads into the disabled set and writes
// back as the same flags. A Rotation row ignores a mask.
@(test)
test_lane_partial_mask_round_trips :: proc(t: ^testing.T) {
	src := `{"length": 1.0, "channels": [
		{"target": "", "path": 2, "times": [0.0], "values": [[1, 2, 3, 0]], "lanes": [true, false, true]},
		{"target": "", "path": 1, "times": [0.0], "values": [[0, 0, 0, 1]], "lanes": [false, true, true, true]}]}`
	clip: anim.AnimationClip
	err := json.unmarshal(transmute([]byte)src, &clip, .JSON, context.allocator)
	defer anim.type_cleanup_AnimationClip(&clip)
	testing.expect(t, err == nil, "the clip unmarshals")
	if len(clip.channels) != 2 do return
	ch := &clip.channels[0]
	testing.expect_value(t, ch.lanes_off, anim.Channel_Lanes_Off{1})
	testing.expect(t, !anim.animation_channel_lane_on(ch, .Vec3, 1), "y is off")
	testing.expect(t, anim.animation_channel_lane_on(ch, .Vec3, 0) && anim.animation_channel_lane_on(ch, .Vec3, 2), "x and z are on")
	testing.expect_value(t, anim.animation_channel_lanes_off(&clip.channels[1], .Vec3), anim.Lane_Set{})

	data, merr := json.marshal(clip, {spec = .JSON}, context.temp_allocator)
	testing.expect(t, merr == nil, "the clip marshals")
	lanes, has := _lanes_json(t, data)
	testing.expect(t, has, "a row with a disabled lane writes lanes")
	if has && testing.expect_value(t, len(lanes), 4) {
		want := [4]bool{true, false, true, true}
		for l in 0 ..< 4 do testing.expect_value(t, bool(lanes[l].(json.Boolean)), want[l])
	}

	again: anim.AnimationClip
	err = json.unmarshal(data, &again, .JSON, context.allocator)
	defer anim.type_cleanup_AnimationClip(&again)
	testing.expect(t, err == nil, "the written clip unmarshals")
	if len(again.channels) == 2 do testing.expect_value(t, again.channels[0].lanes_off, anim.Channel_Lanes_Off{1})
}

// --- The Animation window and the inspector -----------------------------------------------

@(private = "file")
_DIR :: "moonhug/tests/fixtures/_lane_tmp"

@(private = "file")
_CLIP :: `{
  "__type_guid": "0a4f3b1c-8e57-4c2d-9b6a-5d1e7f2c8a90",
  "length": 2.0,
  "channels": []
}`

// An empty two-second clip as the document the window edits, with the undo
// hooks the inspector installs and Record's providers.
@(private = "file")
_lane_open_clip :: proc(t: ^testing.T) -> ^inspector.Asset_Doc {
	os.make_directory(_DIR)
	path :: _DIR + "/Lanes.anim"
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string(_CLIP)) == nil, "the clip file is written")
	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init(_DIR)
	undo.set_asset_apply(inspector.asset_doc_apply_json)
	undo.set_asset_doc_lookup(inspector.asset_doc_payload_ptr)
	animation_editor.animation_record_install()

	doc := inspector.asset_doc_get(path)
	testing.expect(t, doc != nil && doc.data.id == typeid_of(anim.AnimationClip), "the clip loads as a document")
	return doc
}

@(private = "file")
_lane_close :: proc() {
	animation_editor.animation_record_reset()
	undo.commit_listener = nil
	inspector.driven_provider = nil
	inspector.driven_commit = nil
	inspector.driven_row_state = nil
	inspector.driven_add_key = nil
	inspector.driven_delete_key = nil
	inspector.driven_tooltip_read_only = ""
	inspector.driven_tooltip_editable = ""
	inspector.driven_tooltip_add_key = ""
	inspector.asset_docs_shutdown()
	engine.asset_db_shutdown()
	common.remove_tree(_DIR)
	common.remove_tree(engine.library_dir())
}

@(private = "file")
_lane_doc_clip :: proc(doc: ^inspector.Asset_Doc) -> ^anim.AnimationClip {
	return cast(^anim.AnimationClip)doc.data.data
}

// Appends a row to the clip document, allocated the way the document's own
// rows are.
@(private = "file")
_lane_doc_row :: proc(clip: ^anim.AnimationClip, ch: anim.Animation_Channel, keys: []f32, values: [][4]f32) {
	context.allocator = inspector.doc_alloc()
	c := ch
	c.target = strings.clone(ch.target)
	c.component = strings.clone(ch.component)
	c.field = strings.clone(ch.field)
	c.times = make([dynamic]f32)
	c.values = make([dynamic][4]f32)
	for k in keys do append(&c.times, k)
	for v in values do append(&c.values.([dynamic][4]f32), v)
	append(&clip.channels, c)
}

@(private = "file")
_lane_comp :: proc(owner: engine.Transform_Handle, key: engine.TypeKey) -> engine.Handle {
	w := engine.ctx_world()
	tr := engine.pool_get(&w.transforms, engine.Handle(owner))
	if tr == nil do return {}
	for c in tr.components {
		if c.handle.type_key == key do return c.handle
	}
	return {}
}

// Remove Lane disables one lane per undo step, and on the last enabled lane
// removes the row in that same step. Undo brings the row back with its mask.
@(test)
test_lane_remove_last_lane_removes_row :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _lane_open_clip(t)
	defer _lane_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	engine.transform_new("Arm", root)
	_lane_doc_row(_lane_doc_clip(doc), {target = "Arm", path = .Position}, {0, 1}, {{0, 0, 0, 0}, {1, 2, 3, 0}})
	animation_editor.animation_record_arm(root, doc.ref, 0, armed = false)

	before := s.top
	testing.expect(t, animation_editor.animation_window_set_lane(0, 0, false), "x goes off")
	testing.expect_value(t, _lane_doc_clip(doc).channels[0].lanes_off, anim.Channel_Lanes_Off{0})
	testing.expect_value(t, s.top, before + 1)
	testing.expect(t, !animation_editor.animation_window_set_lane(0, 0, false), "x is already off")
	testing.expect(t, !animation_editor.animation_window_set_lane(0, 3, false), "a Position row has no w")
	testing.expect(t, animation_editor.animation_window_set_lane(0, 2, false), "z goes off")
	testing.expect_value(t, s.top, before + 2)

	testing.expect(t, animation_editor.animation_window_set_lane(0, 1, false), "the last lane goes off")
	testing.expect_value(t, len(_lane_doc_clip(doc).channels), 0)
	testing.expect_value(t, s.top, before + 3)

	testing.expect(t, undo.apply_undo(s), "undo")
	clip := _lane_doc_clip(doc)
	testing.expect_value(t, len(clip.channels), 1)
	if len(clip.channels) == 1 do testing.expect_value(t, clip.channels[0].lanes_off, anim.Channel_Lanes_Off{0, 2})

	testing.expect(t, animation_editor.animation_window_set_lane(0, 0, true), "Enable Lane turns x back on")
	testing.expect_value(t, _lane_doc_clip(doc).channels[0].lanes_off, anim.Channel_Lanes_Off{2})
}

// The inspector's driven value fills the disabled lanes from the live field,
// for a transform position and a component field. Recording the vector
// enables every lane.
@(test)
test_lane_driven_value_fills_disabled_lanes :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _lane_open_clip(t)
	defer _lane_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	arm := engine.transform_new("Arm", root)
	w := engine.ctx_world()
	tr := engine.pool_get(&w.transforms, engine.Handle(arm))
	tr.position = {5, 9, 7}
	_, vp := engine.transform_add_comp(arm, .Volume)
	volume := cast(^engine.Volume)vp
	volume.size = {1, 2, 3}

	clip := _lane_doc_clip(doc)
	_lane_doc_row(clip, {target = "Arm", path = .Position, lanes_off = {0, 2}}, {0, 2}, {{0, 0, 0, 0}, {2, 4, 6, 0}})
	_lane_doc_row(clip, {target = "Arm", component = _volume_guid_str(), field = "size", lanes_off = {0, 2}}, {0, 2}, {{0, 0, 0, 0}, {10, 20, 30, 0}})
	animation_editor.animation_record_arm(root, doc.ref, 1, armed = false)

	pos: [3]f32
	driven, _, _ := inspector.driven_provider(engine.Handle(arm), offset_of(engine.Transform, position), typeid_of([3]f32), &pos)
	testing.expect(t, driven, "the position is driven")
	testing.expect_value(t, pos, [3]f32{5, 2, 7})

	size: [3]f32
	driven, _, _ = inspector.driven_provider(_lane_comp(arm, .Volume), offset_of(engine.Volume, size), typeid_of([3]f32), &size)
	testing.expect(t, driven, "the size is driven")
	testing.expect_value(t, size, [3]f32{1, 10, 3})

	animation_editor.animation_record_arm(root, doc.ref, 1, armed = true)
	edited := [3]f32{8, 8, 8}
	testing.expect(t, inspector.driven_commit(engine.Handle(arm), offset_of(engine.Transform, position), typeid_of([3]f32), &edited), "the commit keys the position")
	testing.expect_value(t, _lane_doc_clip(doc).channels[0].lanes_off, anim.Channel_Lanes_Off{})
	testing.expect_value(t, tr.position, [3]f32{5, 9, 7})
}

// An Euler row with only y enabled turns the transform around y, the other
// angles from the rotation at bind time. Two clips with euler keys blend as
// quaternions: 350 and 10 degrees at half weight give 0, not 180.
@(test)
test_lane_euler_rows_play_as_quaternions :: proc(t: ^testing.T) {
	lt: _Lane_Test
	_lane_setup(&lt)
	context.user_ptr = &lt.tc.uc
	defer _lane_teardown(&lt)

	w := engine.ctx_world()
	tr := engine.pool_get(&w.transforms, engine.Handle(lt.owner))
	tr.rotation = anim.animation_quat_from_euler({10, 20, 30})

	// y stays clear of 90, where x and z lose their meaning.
	a := _lane_clip()
	_lane_row(&a, .Euler, "", {0, 60, 0, 0}, {0, 2})
	a_ref := engine.PPtr{guid = _clip_guid(0xB4)}
	anim.animation_clip_cache[a_ref] = a
	leaf := anim.playable_add(&lt.g, anim.Playable_Clip{clip = a_ref})
	anim.animation_pose_apply(&lt.b, anim.playable_graph_evaluate(&lt.g, leaf, &lt.b))
	e := engine.quat_to_euler_xyz(tr.rotation)
	testing.expectf(t, _near3(e, {10, 60, 30}), "y from the row, x and z from the bind rotation, got %v", e)

	b := _lane_clip()
	_lane_row(&b, .Euler, "", {0, 350, 0, 0}, {})
	c := _lane_clip()
	_lane_row(&c, .Euler, "", {0, 10, 0, 0}, {})
	b_ref, c_ref := engine.PPtr{guid = _clip_guid(0xB5)}, engine.PPtr{guid = _clip_guid(0xB6)}
	anim.animation_clip_cache[b_ref] = b
	anim.animation_clip_cache[c_ref] = c
	mixer := anim.playable_add(&lt.g, anim.Playable_Mixer{})
	anim.playable_connect(&lt.g, mixer, anim.playable_add(&lt.g, anim.Playable_Clip{clip = b_ref}), 0.5)
	anim.playable_connect(&lt.g, mixer, anim.playable_add(&lt.g, anim.Playable_Clip{clip = c_ref}), 0.5)
	anim.animation_pose_apply(&lt.b, anim.playable_graph_evaluate(&lt.g, mixer, &lt.b))
	e = engine.quat_to_euler_xyz(tr.rotation)
	testing.expectf(t, abs(e.x) < 0.5 && abs(e.y) < 0.5 && abs(e.z) < 0.5, "350 and 10 blend to 0 as quaternions, got %v", e)
}

