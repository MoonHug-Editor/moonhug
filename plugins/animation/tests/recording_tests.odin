package animation_tests

// Record in the Animation window (editor/record.odin). While Record is armed,
// an edit that records undo on the animated object or under it keys the clip
// at the playhead instead of changing the object: the row is created when
// missing, the object keeps its own value, and the clip document edit is the
// only undo step. Every other edit stays an ordinary scene edit.
//
// The edits go through the paths the editor uses: the inspector's field row
// (replayed by the field-row harness) and an edit session on a transform, the
// way the gizmo records a drag.

import "base:runtime"
import "core:encoding/uuid"
import "core:math/linalg"
import "core:os"
import "core:strings"
import "core:testing"
import asset_pipeline "moonhug:editor/assets"
import "moonhug:editor/inspector"
import undo "moonhug:editor/undo"
import "moonhug:packages/engine"
import anim "moonhug:packages/animation"
import "moonhug:packages/engine/editor/importers"
import animation_editor "moonhug:packages/animation/editor"
import common "moonhug:tests/common"
import gfx "moonhug:libs/gfx"

@(private = "file")
_DIR :: "moonhug/tests/fixtures/_record_tmp"

@(private = "file")
_CLIP :: `{
  "__type_guid": "0a4f3b1c-8e57-4c2d-9b6a-5d1e7f2c8a90",
  "length": 2.0,
  "channels": []
}`

// An empty two-second clip as the document the window edits, with the undo
// hooks the inspector installs and Record's listener.
@(private = "file")
_rec_open_clip :: proc(t: ^testing.T) -> ^inspector.Asset_Doc {
	os.make_directory(_DIR)
	path :: _DIR + "/Recorded.anim"
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
_rec_close :: proc() {
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
_rec_clip :: proc(doc: ^inspector.Asset_Doc) -> ^anim.AnimationClip {
	return cast(^anim.AnimationClip)doc.data.data
}

@(private = "file")
_rec_comp :: proc(owner: engine.Transform_Handle, key: engine.TypeKey) -> engine.Handle {
	w := engine.ctx_world()
	tr := engine.pool_get(&w.transforms, engine.Handle(owner))
	if tr == nil do return {}
	for c in tr.components {
		if c.handle.type_key == key do return c.handle
	}
	return {}
}

// Whether a command records a change to a scene object's value.
@(private = "file")
_has_scene_value :: proc(cmd: undo.Command) -> bool {
	#partial switch v in cmd {
	case undo.Value_Command:
		return v.target.kind == .Pooled
	case undo.Group_Command:
		for sub in v.subs do if _has_scene_value(sub) do return true
	}
	return false
}

// The key of `ch` at time `at`, -1 when there is none.
@(private = "file")
_key_at :: proc(ch: ^anim.Animation_Channel, at: f32) -> int {
	for kt, i in ch.times do if abs(kt - at) < 0.0005 do return i
	return -1
}

@(private = "file")
_write_intensity :: proc(field_ptr: rawptr) {
	(cast(^f32)field_ptr)^ = 5
}

@(private = "file")
_write_slot :: proc(field_ptr: rawptr) {
	(cast(^string)field_ptr)^ = strings.clone("Main")
}

// Drags a Light's intensity from 1 to 5 through its inspector row.
@(private = "file")
_drag_intensity :: proc(lamp: engine.Transform_Handle, light: ^engine.Light) {
	undo.push_component_owner(_rec_comp(lamp, .Light))
	defer undo.pop_owner()
	h := common.Row_Harness{
		field_ptr = &light.intensity,
		field_tid = typeid_of(f32),
		offset    = offset_of(engine.Light, intensity),
		label     = "intensity",
	}
	common.row_replay(&h, []common.Frame{
		common.frame_press(_write_intensity),
		common.frame_drag(_write_intensity),
		common.frame_release(),
	})
}

// A component field with no row, on a child of the animated object: the row
// appears with the child's path, the key at the playhead holds the edited
// value, the light keeps its own value, and one undo step adds and removes it.
@(test)
test_record_keys_a_field_without_a_row :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	lamp := engine.transform_new("Lamp", root)
	_, lp := engine.transform_add_comp(lamp, .Light)
	light := cast(^engine.Light)lp
	light.intensity = 1
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 0.5)

	before := s.top
	_drag_intensity(lamp, light)

	clip := _rec_clip(doc)
	testing.expect_value(t, len(clip.channels), 1)
	if len(clip.channels) != 1 do return
	ch := &clip.channels[0]
	light_guid := uuid.to_string(engine.get_guid_by_typeid(engine.Light), context.temp_allocator)
	testing.expect_value(t, ch.target, "Lamp")
	testing.expect_value(t, ch.component, light_guid)
	testing.expect_value(t, ch.field, "intensity")
	at := _key_at(ch, 0.5)
	testing.expect(t, at >= 0, "a key at the playhead")
	if at >= 0 do testing.expect_value(t, ch.values.([dynamic][4]f32)[at].x, 5)
	start := _key_at(ch, 0)
	testing.expect(t, start >= 0, "the new row starts at the clip start")
	if start >= 0 do testing.expect_value(t, ch.values.([dynamic][4]f32)[start].x, 1)
	testing.expect_value(t, light.intensity, 1)

	testing.expect_value(t, s.top, before + 1)
	testing.expect(t, !_has_scene_value(s.items[s.top - 1].cmd), "no scene value step")

	testing.expect(t, undo.apply_undo(s), "undo")
	testing.expect_value(t, len(_rec_clip(doc).channels), 0)
	testing.expect_value(t, light.intensity, 1)
	testing.expect(t, undo.apply_redo(s), "redo")
	clip = _rec_clip(doc)
	testing.expect_value(t, len(clip.channels), 1)
	if len(clip.channels) == 1 {
		at = _key_at(&clip.channels[0], 0.5)
		testing.expect(t, at >= 0 && clip.channels[0].values.([dynamic][4]f32)[at].x == 5, "redo restores the key")
	}
	testing.expect_value(t, light.intensity, 1)
}

// A transform edit session, as the gizmo opens for a drag, keys a Position row.
@(test)
test_record_keys_a_transform_drag :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	child := engine.transform_new("Child", root)
	w := engine.ctx_world()
	tr := engine.pool_get(&w.transforms, engine.Handle(child))
	tr.position = {0, 0, 0}
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 1)

	before := s.top
	sess := undo.edit_session_begin({undo.edit_target_transform(child, &tr.position, typeid_of([3]f32))}, "Move")
	tr.position = {1, 2, 3}
	undo.edit_session_end(&sess)

	clip := _rec_clip(doc)
	testing.expect_value(t, len(clip.channels), 1)
	if len(clip.channels) != 1 do return
	ch := &clip.channels[0]
	testing.expect_value(t, ch.target, "Child")
	testing.expect(t, !anim.animation_channel_is_property(ch), "a transform row")
	testing.expect_value(t, ch.path, anim.Animation_Path.Position)
	at := _key_at(ch, 1)
	testing.expect(t, at >= 0 && ch.values.([dynamic][4]f32)[at].xyz == [3]f32{1, 2, 3}, "the key at the playhead holds the dragged position")
	testing.expect_value(t, tr.position, [3]f32{0, 0, 0})
	testing.expect_value(t, s.top, before + 1)
	testing.expect(t, !_has_scene_value(s.items[s.top - 1].cmd), "no scene value step")
}

// A string field keys a string row: the key at the playhead holds the typed
// text, the key at the clip start the camera's own, the camera keeps its own
// value, and undo and redo take the row away and bring it back.
@(test)
test_record_keys_a_string_edit :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	eye := engine.transform_new("Eye", root)
	_, cp := engine.transform_add_comp(eye, .Camera)
	cam := cast(^engine.Camera)cp
	own := strings.clone(cam.slot, context.temp_allocator)
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 0.5)

	before := s.top
	{
		undo.push_component_owner(_rec_comp(eye, .Camera))
		defer undo.pop_owner()
		h := common.Row_Harness{
			field_ptr = &cam.slot,
			field_tid = typeid_of(string),
			offset    = offset_of(engine.Camera, slot),
			label     = "slot",
		}
		common.row_replay(&h, []common.Frame{common.frame_press(_write_slot), common.frame_release()})
	}

	testing.expect_value(t, cam.slot, own)
	testing.expect_value(t, s.top, before + 1)
	testing.expect(t, !_has_scene_value(s.items[s.top - 1].cmd), "no scene value step")
	clip := _rec_clip(doc)
	testing.expect_value(t, len(clip.channels), 1)
	if len(clip.channels) != 1 do return
	ch := &clip.channels[0]
	testing.expect_value(t, ch.field, "slot")
	strs, is_str := ch.values.([dynamic]string)
	testing.expect(t, is_str, "a string row")
	if !is_str do return
	at := _key_at(ch, 0.5)
	start := _key_at(ch, 0)
	testing.expect(t, at >= 0 && strs[at] == "Main", "the key at the playhead holds the typed text")
	testing.expect(t, start >= 0 && strs[start] == own, "the key at the clip start holds the camera's own text")

	testing.expect(t, undo.apply_undo(s), "undo")
	testing.expect_value(t, len(_rec_clip(doc).channels), 0)
	testing.expect(t, undo.apply_redo(s), "redo")
	clip = _rec_clip(doc)
	testing.expect_value(t, len(clip.channels), 1)
	if len(clip.channels) == 1 {
		strs2, ok2 := clip.channels[0].values.([dynamic]string)
		at = _key_at(&clip.channels[0], 0.5)
		testing.expect(t, ok2 && at >= 0 && strs2[at] == "Main", "redo restores the string key")
	}
}

// An object outside the animated object's subtree is not the clip's to key.
@(test)
test_record_leaves_an_edit_outside_the_root_alone :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	other := engine.transform_new("Other")
	_, lp := engine.transform_add_comp(other, .Light)
	light := cast(^engine.Light)lp
	light.intensity = 1
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 0.5)

	before := s.top
	_drag_intensity(other, light)

	testing.expect_value(t, light.intensity, 5)
	testing.expect_value(t, len(_rec_clip(doc).channels), 0)
	testing.expect_value(t, s.top, before + 1)
	testing.expect(t, _has_scene_value(s.items[s.top - 1].cmd), "a scene value step")
}

// With Record off an edit under the animated object is an ordinary edit.
@(test)
test_record_off_keys_nothing :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	lamp := engine.transform_new("Lamp", root)
	_, lp := engine.transform_add_comp(lamp, .Light)
	light := cast(^engine.Light)lp
	light.intensity = 1
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 0.5, armed = false)

	before := s.top
	_drag_intensity(lamp, light)

	testing.expect_value(t, light.intensity, 5)
	testing.expect_value(t, len(_rec_clip(doc).channels), 0)
	testing.expect_value(t, s.top, before + 1)
	testing.expect(t, _has_scene_value(s.items[s.top - 1].cmd), "a scene value step")
}

// --- Driven values and row values ----------------------------------------------------
//
// While the preview is on, the inspector asks inspector.driven_provider for
// each field and shows the clip's value at the playhead for a field the shown
// clip has a row for. The Animation window's row value fields key the row at
// the playhead.

// Appends a row to the clip document, allocated the way the document's own
// rows are.
@(private = "file")
_rec_add_row :: proc(clip: ^anim.AnimationClip, ch: anim.Animation_Channel, keys: []f32, values: [][4]f32) {
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

// A Light intensity row on "Lamp" under "Root": 1 at 0 s, 3 at 1 s.
@(private = "file")
_rec_intensity_row :: proc(clip: ^anim.AnimationClip) {
	guid := uuid.to_string(engine.get_guid_by_typeid(engine.Light), context.temp_allocator)
	_rec_add_row(clip, {target = "Lamp", component = guid, field = "intensity"}, {0, 1}, {{1, 0, 0, 0}, {3, 0, 0, 0}})
}

@(private = "file")
_ask_f32 :: proc(owner: engine.Handle, offset: uintptr) -> (v: f32, driven, editable: bool) {
	driven, editable, _ = inspector.driven_provider(owner, offset, typeid_of(f32), &v)
	return
}

// A field with a row is driven by the row's value at the playhead,
// interpolated between keys. Editable only while Record is armed.
@(test)
test_driven_value_samples_the_row :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	lamp := engine.transform_new("Lamp", root)
	_, lp := engine.transform_add_comp(lamp, .Light)
	light := cast(^engine.Light)lp
	light.intensity = 7
	_rec_intensity_row(_rec_clip(doc))
	lh := _rec_comp(lamp, .Light)

	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 0.5, armed = false)
	v, driven, editable := _ask_f32(lh, offset_of(engine.Light, intensity))
	testing.expect(t, driven, "the field with a row is driven")
	testing.expect_value(t, v, 2)
	testing.expect(t, !editable, "read-only with Record off")
	testing.expect_value(t, light.intensity, 7)

	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 0.5, armed = true)
	v, driven, editable = _ask_f32(lh, offset_of(engine.Light, intensity))
	testing.expect(t, driven && editable, "editable with Record armed")
	testing.expect_value(t, v, 2)

	// Preview off: nothing is driven.
	animation_editor.animation_record_reset()
	_, driven, _ = _ask_f32(lh, offset_of(engine.Light, intensity))
	testing.expect(t, !driven, "not driven with the preview off")
}

// A field without a row is not driven, and neither is the same field on an
// object outside the animated object, even with a matching name.
@(test)
test_driven_value_needs_a_row_under_the_root :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	lamp := engine.transform_new("Lamp", root)
	engine.transform_add_comp(lamp, .Light)
	outside := engine.transform_new("Lamp")
	engine.transform_add_comp(outside, .Light)
	_rec_intensity_row(_rec_clip(doc))
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 0.5)

	_, driven, _ := _ask_f32(_rec_comp(lamp, .Light), offset_of(engine.Light, range))
	testing.expect(t, !driven, "a field without a row is not driven")
	_, driven, _ = _ask_f32(_rec_comp(outside, .Light), offset_of(engine.Light, intensity))
	testing.expect(t, !driven, "an object outside the animated object is not driven")
	_, driven, _ = _ask_f32(_rec_comp(lamp, .Light), offset_of(engine.Light, intensity))
	testing.expect(t, driven, "the field with a row under the root is driven")
}

// A transform's position is driven by a Position row.
@(test)
test_driven_value_samples_a_position_row :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	arm := engine.transform_new("Arm", root)
	_rec_add_row(_rec_clip(doc), {target = "Arm", path = .Position}, {0, 2}, {{0, 0, 0, 0}, {2, 4, 6, 0}})
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 1, armed = false)

	pos: [3]f32
	driven, editable, _ := inspector.driven_provider(engine.Handle(arm), offset_of(engine.Transform, position), typeid_of([3]f32), &pos)
	testing.expect(t, driven && !editable, "the position is driven, read-only")
	testing.expect_value(t, pos, [3]f32{1, 2, 3})

	scale: [3]f32
	driven, _, _ = inspector.driven_provider(engine.Handle(arm), offset_of(engine.Transform, scale), typeid_of([3]f32), &scale)
	testing.expect(t, !driven, "the scale has no row")
}

// The row value field keys the row at the playhead: a key already there takes
// the value, else a key is added. Each is one undo step on the clip.
@(test)
test_row_value_keys_at_the_playhead :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	lamp := engine.transform_new("Lamp", root)
	engine.transform_add_comp(lamp, .Light)
	_rec_intensity_row(_rec_clip(doc))

	// A key at the playhead takes the value.
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 1, armed = false)
	before := s.top
	animation_editor.animation_record_key_row(0, {9, 0, 0, 0})
	ch := &_rec_clip(doc).channels[0]
	testing.expect_value(t, len(ch.times), 2)
	testing.expect_value(t, ch.values.([dynamic][4]f32)[1].x, 9)
	testing.expect_value(t, s.top, before + 1)
	testing.expect(t, undo.apply_undo(s), "undo")
	ch = &_rec_clip(doc).channels[0]
	testing.expect_value(t, ch.values.([dynamic][4]f32)[1].x, 3)

	// No key at the playhead: one is added between the others.
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 0.5, armed = false)
	before = s.top
	animation_editor.animation_record_key_row(0, {4, 0, 0, 0})
	ch = &_rec_clip(doc).channels[0]
	testing.expect_value(t, len(ch.times), 3)
	at := _key_at(ch, 0.5)
	testing.expect_value(t, at, 1)
	if at >= 0 do testing.expect_value(t, ch.values.([dynamic][4]f32)[at].x, 4)
	testing.expect_value(t, s.top, before + 1)
	testing.expect(t, undo.apply_undo(s), "undo")
	testing.expect_value(t, len(_rec_clip(doc).channels[0].times), 2)
}

// Through the inspector's row: with Record off a driven row is read-only, so
// a drag changes neither the object nor the undo stack. With Record armed the
// drag keys the row at the playhead and the object keeps its own value.
@(test)
test_driven_row_through_the_inspector :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	lamp := engine.transform_new("Lamp", root)
	_, lp := engine.transform_add_comp(lamp, .Light)
	light := cast(^engine.Light)lp
	light.intensity = 1
	_rec_intensity_row(_rec_clip(doc))

	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 0.5, armed = false)
	before := s.top
	_drag_intensity(lamp, light)
	testing.expect_value(t, light.intensity, 1)
	testing.expect_value(t, s.top, before)
	testing.expect_value(t, len(_rec_clip(doc).channels[0].times), 2)

	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 0.5, armed = true)
	_drag_intensity(lamp, light)
	testing.expect_value(t, light.intensity, 1)
	testing.expect_value(t, s.top, before + 1)
	testing.expect(t, !_has_scene_value(s.items[s.top - 1].cmd), "no scene value step")
	ch := &_rec_clip(doc).channels[0]
	at := _key_at(ch, 0.5)
	testing.expect(t, at >= 0, "a key at the playhead")
	if at >= 0 do testing.expect_value(t, ch.values.([dynamic][4]f32)[at].x, 5)
}

@(private = "file")
_write_one :: proc(field_ptr: rawptr) {
	(cast(^f32)field_ptr)^ = 1
}

// An inspector edit while recording keys the value even when it equals the
// object's own value: the edit goes to inspector.driven_commit, not through a
// scene session whose "before" is the object's own value. The live scale
// stays, and the key is the gesture's one undo step.
@(test)
test_driven_commit_keys_the_objects_own_value :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	arm := engine.transform_new("Arm", root)
	w := engine.ctx_world()
	tr := engine.pool_get(&w.transforms, engine.Handle(arm))
	tr.scale = {1, 1, 1}
	_rec_add_row(_rec_clip(doc), {target = "Arm", path = .Scale}, {0, 2}, {{2, 2, 2, 0}, {2, 2, 2, 0}})
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 1)

	shown: [3]f32
	driven, editable, _ := inspector.driven_provider(engine.Handle(arm), offset_of(engine.Transform, scale), typeid_of([3]f32), &shown)
	testing.expect(t, driven && editable, "the scale is driven and editable")
	testing.expect_value(t, shown, [3]f32{2, 2, 2})

	before := s.top
	one := [3]f32{1, 1, 1}
	ok := inspector.driven_commit(engine.Handle(arm), offset_of(engine.Transform, scale), typeid_of([3]f32), &one)
	testing.expect(t, ok, "the commit keys the field")

	ch := &_rec_clip(doc).channels[0]
	at := _key_at(ch, 1)
	testing.expect(t, at >= 0, "a key at the playhead")
	if at >= 0 do testing.expect_value(t, ch.values.([dynamic][4]f32)[at].xyz, [3]f32{1, 1, 1})
	testing.expect_value(t, tr.scale, [3]f32{1, 1, 1})
	testing.expect_value(t, s.top, before + 1)
	testing.expect(t, !_has_scene_value(s.items[s.top - 1].cmd), "no scene value step")

	testing.expect(t, undo.apply_undo(s), "undo")
	testing.expect_value(t, len(_rec_clip(doc).channels[0].times), 2)

	// Record off: the commit goes nowhere.
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 1, armed = false)
	testing.expect(t, !inspector.driven_commit(engine.Handle(arm), offset_of(engine.Transform, scale), typeid_of([3]f32), &one), "nothing is keyed with Record off")
}

// The same through the inspector's row: a drag of a driven intensity back to
// the light's own value keys it.
@(test)
test_driven_row_keys_the_objects_own_value :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	lamp := engine.transform_new("Lamp", root)
	_, lp := engine.transform_add_comp(lamp, .Light)
	light := cast(^engine.Light)lp
	light.intensity = 1
	_rec_intensity_row(_rec_clip(doc))
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 0.5)

	before := s.top
	{
		undo.push_component_owner(_rec_comp(lamp, .Light))
		defer undo.pop_owner()
		h := common.Row_Harness{
			field_ptr = &light.intensity,
			field_tid = typeid_of(f32),
			offset    = offset_of(engine.Light, intensity),
			label     = "intensity",
		}
		common.row_replay(&h, []common.Frame{
			common.frame_press(_write_one),
			common.frame_drag(_write_one),
			common.frame_release(),
		})
	}

	ch := &_rec_clip(doc).channels[0]
	at := _key_at(ch, 0.5)
	testing.expect(t, at >= 0, "a key at the playhead")
	if at >= 0 do testing.expect_value(t, ch.values.([dynamic][4]f32)[at].x, 1)
	testing.expect_value(t, light.intensity, 1)
	testing.expect_value(t, s.top, before + 1)
	testing.expect(t, !_has_scene_value(s.items[s.top - 1].cmd), "no scene value step")
}

// A Rotation row shows euler angles and keys the quaternion built from them:
// keying (0, 90, 0) stores a unit quaternion that reads back as (0, 90, 0).
@(test)
test_rotation_row_euler_round_trip :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	engine.transform_new("Arm", root)
	_rec_add_row(_rec_clip(doc), {target = "Arm", path = .Rotation}, {0}, {{0, 0, 0, 1}})
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 1, armed = false)

	animation_editor.animation_record_key_row_euler(0, {0, 90, 0})
	ch := &_rec_clip(doc).channels[0]
	at := _key_at(ch, 1)
	testing.expect(t, at >= 0, "a key at the playhead")
	if at < 0 do return
	q := ch.values.([dynamic][4]f32)[at]
	testing.expect(t, abs(linalg.length(q) - 1) < 1e-4, "the key is a unit quaternion")
	e := engine.quat_to_euler_xyz(q)
	EPS :: f32(0.01)
	testing.expectf(t, abs(e.x) < EPS && abs(e.y - 90) < EPS && abs(e.z) < EPS, "the key reads back as (0, 90, 0), got %v", e)
}

// The mark and "Add Key" ask inspector.driven_row_state: a field with a row
// in the shown clip has one, a field without has none, and both are keyable
// on the animated object or under it while Record is armed. An object
// outside the animated object is neither.
@(test)
test_row_state_answers_rows_and_keyable :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	lamp := engine.transform_new("Lamp", root)
	engine.transform_add_comp(lamp, .Light)
	outside := engine.transform_new("Lamp")
	engine.transform_add_comp(outside, .Light)
	_rec_intensity_row(_rec_clip(doc))
	lh := _rec_comp(lamp, .Light)

	// Keyable only while recording. Keyed when the playhead sits on a key:
	// the intensity row has keys at 0 and 1, so 0.5 sits between them.
	for armed in ([2]bool{false, true}) {
		animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 0.5, armed = armed)
		has_row, keyable, keyed := inspector.driven_row_state(lh, offset_of(engine.Light, intensity), typeid_of(f32))
		testing.expect(t, has_row && keyable == armed && !keyed, "the field with a row has a row, is keyable while recording, and has no key at 0.5")
		has_row, keyable, keyed = inspector.driven_row_state(lh, offset_of(engine.Light, range), typeid_of(f32))
		testing.expect(t, !has_row && keyable == armed && !keyed, "a field without a row has none and is keyable while recording")
		has_row, keyable, keyed = inspector.driven_row_state(_rec_comp(outside, .Light), offset_of(engine.Light, intensity), typeid_of(f32))
		testing.expect(t, !has_row && !keyable && !keyed, "an object outside the animated object is neither")
		has_row, keyable, keyed = inspector.driven_row_state(engine.Handle(lamp), offset_of(engine.Transform, position), typeid_of([3]f32))
		testing.expect(t, !has_row && keyable == armed && !keyed, "a transform channel without a row is keyable while recording")
	}
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 1.0, armed = false)
	_, _, keyed := inspector.driven_row_state(lh, offset_of(engine.Light, intensity), typeid_of(f32))
	testing.expect(t, keyed, "the playhead on the row's key at 1.0 reads keyed")

	// No clip shown: nothing has a row, nothing is keyable.
	animation_editor.animation_record_reset()
	has_row, keyable, _ := inspector.driven_row_state(lh, offset_of(engine.Light, intensity), typeid_of(f32))
	testing.expect(t, !has_row && !keyable, "nothing without a shown clip")
}

// "Add Key" with Record off keys the field's live value at the playhead: the
// row is created (its start key holds the object's own value), the light
// keeps its value, and the key is one undo step on the clip.
@(test)
test_add_key_with_record_off_keys_the_live_value :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	lamp := engine.transform_new("Lamp", root)
	_, lp := engine.transform_add_comp(lamp, .Light)
	light := cast(^engine.Light)lp
	light.intensity = 3
	lh := _rec_comp(lamp, .Light)
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 0.5, armed = false)

	before := s.top
	ok := inspector.driven_add_key(lh, offset_of(engine.Light, intensity), typeid_of(f32), &light.intensity)
	testing.expect(t, ok, "the field is keyed with Record off")

	clip := _rec_clip(doc)
	testing.expect_value(t, len(clip.channels), 1)
	if len(clip.channels) != 1 do return
	ch := &clip.channels[0]
	testing.expect_value(t, ch.target, "Lamp")
	testing.expect_value(t, ch.field, "intensity")
	at := _key_at(ch, 0.5)
	testing.expect(t, at >= 0, "a key at the playhead")
	if at >= 0 do testing.expect_value(t, ch.values.([dynamic][4]f32)[at].x, 3)
	start := _key_at(ch, 0)
	testing.expect(t, start >= 0, "the new row starts at the clip start")
	if start >= 0 do testing.expect_value(t, ch.values.([dynamic][4]f32)[start].x, 3)
	testing.expect_value(t, light.intensity, 3)
	testing.expect_value(t, s.top, before + 1)
	testing.expect(t, !_has_scene_value(s.items[s.top - 1].cmd), "no scene value step")

	has_row, _, _ := inspector.driven_row_state(lh, offset_of(engine.Light, intensity), typeid_of(f32))
	testing.expect(t, has_row, "the field has a row after the key")

	testing.expect(t, undo.apply_undo(s), "undo")
	testing.expect_value(t, len(_rec_clip(doc).channels), 0)
	testing.expect_value(t, light.intensity, 3)

	// An object outside the animated object is not keyed.
	outside := engine.transform_new("Lamp")
	_, op := engine.transform_add_comp(outside, .Light)
	before = s.top
	testing.expect(t, !inspector.driven_add_key(_rec_comp(outside, .Light), offset_of(engine.Light, intensity), typeid_of(f32), &(cast(^engine.Light)op).intensity), "nothing is keyed outside the root")
	testing.expect_value(t, s.top, before)
}

// A clip inside a model has no document: no field is keyable, and "Add Key"
// keys nothing.
@(test)
test_row_state_not_keyable_in_a_model_clip :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)

	dir :: "moonhug/tests/fixtures/_record_model_tmp"
	gltf :: dir + "/box.gltf"
	os.make_directory(dir)
	bytes, rerr := os.read_entire_file("moonhug/tests/fixtures/meshes/box_animated.gltf", context.temp_allocator)
	testing.expect(t, rerr == nil, "the model fixture reads")
	if rerr != nil do return
	testing.expect(t, os.write_entire_file(gltf, bytes) == nil, "the model is written")
	asset_pipeline.asset_pipeline_init()
	importers.gltf_clip_baker = animation_editor.bake_gltf_clip
	engine.asset_db_init(dir)
	defer {
		engine.asset_db_shutdown()
		common.remove_tree(dir)
		common.remove_tree(engine.library_dir())
	}
	_ = asset_pipeline.asset_pipeline_import_asset(gltf)
	animation_editor.animation_record_install()
	defer {
		animation_editor.animation_record_reset()
		undo.commit_listener = nil
		inspector.driven_provider = nil
		inspector.driven_commit = nil
		inspector.driven_row_state = nil
		inspector.driven_add_key = nil
	}

	model_raw, mok := engine.asset_db_get_guid(gltf)
	testing.expect(t, mok, "the model is registered")
	if !mok do return
	model := engine.Asset_GUID(model_raw)
	clips := engine.mesh_clips(model)
	testing.expect(t, len(clips) >= 1, "the model lists its clips")
	if len(clips) == 0 do return

	root := engine.transform_new("Root")
	lamp := engine.transform_new("Lamp", root)
	_, lp := engine.transform_add_comp(lamp, .Light)
	light := cast(^engine.Light)lp
	lh := _rec_comp(lamp, .Light)

	// The clip cache allocates under the default allocator and frees under
	// the ambient one, so the whole exchange runs under default.
	context.allocator = runtime.default_allocator()
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	model_clip := engine.PPtr{guid = model, local_id = clips[0].id}
	loaded, lok := anim.animation_clip_load(model_clip)
	testing.expect(t, lok && loaded != nil, "the clip inside the model loads")
	animation_editor.animation_record_arm(root, model_clip, 0.5, armed = false)

	_, keyable, _ := inspector.driven_row_state(lh, offset_of(engine.Light, intensity), typeid_of(f32))
	testing.expect(t, !keyable, "a field is not keyable in a clip inside a model")
	_, keyable, _ = inspector.driven_row_state(engine.Handle(root), offset_of(engine.Transform, position), typeid_of([3]f32))
	testing.expect(t, !keyable, "a transform channel is not keyable in a clip inside a model")
	before := s.top
	testing.expect(t, !inspector.driven_add_key(lh, offset_of(engine.Light, intensity), typeid_of(f32), &light.intensity), "nothing is keyed in a clip inside a model")
	testing.expect_value(t, s.top, before)
}

// "Delete Key" removes the row's key on the playhead's frame as one undo
// step, and a row left without keys goes with it.
@(test)
test_delete_key_removes_the_playhead_key :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	lamp := engine.transform_new("Lamp", root)
	engine.transform_add_comp(lamp, .Light)
	_rec_intensity_row(_rec_clip(doc))
	lh := _rec_comp(lamp, .Light)
	off := offset_of(engine.Light, intensity)

	// Between the keys there is nothing to delete.
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 0.5)
	testing.expect(t, !inspector.driven_delete_key(lh, off, typeid_of(f32)), "no key at 0.5 to delete")

	// On the key at 1.0: gone, one undo step, the row keeps its other key.
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 1.0)
	top := s.top
	testing.expect(t, inspector.driven_delete_key(lh, off, typeid_of(f32)), "the key at 1.0 is deleted")
	testing.expect_value(t, s.top, top + 1)
	_, _, keyed := inspector.driven_row_state(lh, off, typeid_of(f32))
	testing.expect(t, !keyed, "no key at 1.0 any more")
	has_row, _, _ := inspector.driven_row_state(lh, off, typeid_of(f32))
	testing.expect(t, has_row, "the row stays while it has a key")

	// The last key takes the row with it.
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 0.0)
	testing.expect(t, inspector.driven_delete_key(lh, off, typeid_of(f32)), "the key at 0 is deleted")
	has_row, _, _ = inspector.driven_row_state(lh, off, typeid_of(f32))
	testing.expect(t, !has_row, "a row without keys is gone")
}


// --- Split rows and Euler rows -------------------------------------------------------
//
// A split row (editor/lane_split.odin) is one channel per lane. Recording into
// it keys only the lanes the edit changed, "Add Key" keys every lane, the
// provider reads each lane from its own channel, and "Delete Key" removes the
// playhead key in every lane. The rotation field is recorded into an Euler row
// and reads as euler angles or as a quaternion.

// A split Position row on "Arm": x, y and z each in a channel of their own,
// masked to their lane, keyed at `x`, `y` and `z` with the values `xv`, `yv`
// and `zv` in their own lane.
@(private = "file")
_rec_split_position :: proc(clip: ^anim.AnimationClip, x, y, z: []f32, xv, yv, zv: []f32) {
	masks := [3]anim.Channel_Lanes_Off{{1, 2}, {0, 2}, {0, 1}}
	times := [3][]f32{x, y, z}
	vals := [3][]f32{xv, yv, zv}
	for l in 0 ..< 3 {
		v := make([][4]f32, len(vals[l]), context.temp_allocator)
		for f, i in vals[l] do v[i][l] = f
		_rec_add_row(clip, {target = "Arm", path = .Position, lanes_off = masks[l]}, times[l], v)
	}
}

// An edit session on a split position row that changes only y keys the y
// channel at the playhead, and leaves the x and z channels without a key there.
@(test)
test_record_into_a_split_row_keys_only_the_changed_lane :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	arm := engine.transform_new("Arm", root)
	w := engine.ctx_world()
	tr := engine.pool_get(&w.transforms, engine.Handle(arm))
	tr.position = {1, 2, 3}
	_rec_split_position(_rec_clip(doc), {0}, {0}, {0}, {1}, {2}, {3})
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 1)

	before := s.top
	sess := undo.edit_session_begin({undo.edit_target_transform(arm, &tr.position, typeid_of([3]f32))}, "Move")
	tr.position = {1, 5, 3}
	undo.edit_session_end(&sess)

	clip := _rec_clip(doc)
	if !testing.expect_value(t, len(clip.channels), 3) do return
	testing.expect_value(t, _key_at(&clip.channels[0], 1), -1)
	testing.expect_value(t, _key_at(&clip.channels[2], 1), -1)
	at := _key_at(&clip.channels[1], 1)
	testing.expect(t, at >= 0, "the y channel has a key at the playhead")
	if at >= 0 do testing.expect_value(t, clip.channels[1].values.([dynamic][4]f32)[at].y, 5)
	masks := [3]anim.Channel_Lanes_Off{{1, 2}, {0, 2}, {0, 1}}
	for l in 0 ..< 3 do testing.expect_value(t, clip.channels[l].lanes_off, masks[l])
	testing.expect_value(t, tr.position, [3]f32{1, 2, 3})
	testing.expect_value(t, s.top, before + 1)
}

// The provider reads a split row lane by lane, each lane from its own channel
// at the playhead.
@(test)
test_driven_value_merges_split_channels :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	arm := engine.transform_new("Arm", root)
	// x: 0 to 2 over 2 s, y: 7 throughout, z: 0 to 10 from 0.5 s to 1.5 s.
	_rec_split_position(_rec_clip(doc), {0, 2}, {1}, {0.5, 1.5}, {0, 2}, {7}, {0, 10})
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 1, armed = false)

	pos: [3]f32
	driven, _, _ := inspector.driven_provider(engine.Handle(arm), offset_of(engine.Transform, position), typeid_of([3]f32), &pos)
	testing.expect(t, driven, "the position is driven")
	testing.expect_value(t, pos, [3]f32{1, 7, 5})
}

// On a split row an inspector commit keys only the lanes that differ from the
// value the rows show at the playhead, and "Add Key" keys every lane.
@(test)
test_split_row_commit_keys_changed_lanes_add_key_keys_all :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	arm := engine.transform_new("Arm", root)
	_rec_split_position(_rec_clip(doc), {0}, {0}, {0}, {1}, {2}, {3})
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 1)

	edited := [3]f32{1, 2, 9}
	testing.expect(t, inspector.driven_commit(engine.Handle(arm), offset_of(engine.Transform, position), typeid_of([3]f32), &edited), "the commit keys the position")
	clip := _rec_clip(doc)
	testing.expect_value(t, _key_at(&clip.channels[0], 1), -1)
	testing.expect_value(t, _key_at(&clip.channels[1], 1), -1)
	at := _key_at(&clip.channels[2], 1)
	testing.expect(t, at >= 0 && clip.channels[2].values.([dynamic][4]f32)[at].z == 9, "the z channel takes the edit")

	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 1.5, armed = false)
	added := [3]f32{4, 5, 6}
	testing.expect(t, inspector.driven_add_key(engine.Handle(arm), offset_of(engine.Transform, position), typeid_of([3]f32), &added), "Add Key keys the position")
	clip = _rec_clip(doc)
	for l in 0 ..< 3 {
		k := _key_at(&clip.channels[l], 1.5)
		testing.expectf(t, k >= 0, "lane %d has a key at the playhead", l)
		if k >= 0 do testing.expect_value(t, clip.channels[l].values.([dynamic][4]f32)[k][l], added[l])
	}
}

@(private = "file")
_near_euler :: proc(a, b: [3]f32) -> bool {
	EPS :: f32(0.01)
	return abs(a.x - b.x) < EPS && abs(a.y - b.y) < EPS && abs(a.z - b.z) < EPS
}

// A recorded rotation edit with no row creates an Euler row: the key at the
// clip start holds the old angles, the key at the playhead the new ones, and
// the transform keeps its own rotation.
@(test)
test_record_rotation_creates_an_euler_row :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	arm := engine.transform_new("Arm", root)
	w := engine.ctx_world()
	tr := engine.pool_get(&w.transforms, engine.Handle(arm))
	own := anim.animation_quat_from_euler({10, 20, 30})
	tr.rotation = own
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 1)

	before := s.top
	sess := undo.edit_session_begin({undo.edit_target_transform(arm, &tr.rotation, typeid_of([4]f32))}, "Rotate")
	tr.rotation = anim.animation_quat_from_euler({10, 50, 30})
	undo.edit_session_end(&sess)

	clip := _rec_clip(doc)
	if !testing.expect_value(t, len(clip.channels), 1) do return
	ch := &clip.channels[0]
	testing.expect_value(t, ch.target, "Arm")
	testing.expect_value(t, ch.path, anim.Animation_Path.Euler)
	testing.expect_value(t, ch.lanes_off, anim.Channel_Lanes_Off{})
	vals := ch.values.([dynamic][4]f32)
	start := _key_at(ch, 0)
	at := _key_at(ch, 1)
	testing.expect(t, start >= 0 && at >= 0, "keys at the clip start and at the playhead")
	if start >= 0 do testing.expectf(t, _near_euler(vals[start].xyz, {10, 20, 30}), "the start key holds the old angles, got %v", vals[start].xyz)
	if at >= 0 do testing.expectf(t, _near_euler(vals[at].xyz, {10, 50, 30}), "the playhead key holds the new angles, got %v", vals[at].xyz)
	testing.expect_value(t, tr.rotation, own)
	testing.expect_value(t, s.top, before + 1)
}

// The provider answers the rotation field from an Euler row as euler angles
// ([3]f32) and as a quaternion ([4]f32). A masked Euler row takes the other
// angles from the transform's own rotation.
@(test)
test_driven_rotation_reads_an_euler_row_as_angles_or_quaternion :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	arm := engine.transform_new("Arm", root)
	w := engine.ctx_world()
	tr := engine.pool_get(&w.transforms, engine.Handle(arm))
	tr.rotation = anim.animation_quat_from_euler({20, 0, 0})
	// Only y animates: 0 to 90 over 2 s.
	_rec_add_row(_rec_clip(doc), {target = "Arm", path = .Euler, lanes_off = {0, 2}}, {0, 2}, {{0, 0, 0, 0}, {0, 90, 0, 0}})
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 1, armed = false)

	e: [3]f32
	driven, _, _ := inspector.driven_provider(engine.Handle(arm), offset_of(engine.Transform, rotation), typeid_of([3]f32), &e)
	testing.expect(t, driven, "the rotation is driven as euler angles")
	testing.expectf(t, _near_euler(e, {20, 45, 0}), "y from the row, x and z from the transform, got %v", e)

	q: [4]f32
	driven, _, _ = inspector.driven_provider(engine.Handle(arm), offset_of(engine.Transform, rotation), typeid_of([4]f32), &q)
	testing.expect(t, driven, "the rotation is driven as a quaternion")
	want := anim.animation_quat_from_euler({20, 45, 0})
	testing.expectf(t, linalg.length(q - want) < 1e-4 || linalg.length(q + want) < 1e-4, "the quaternion of the same angles, got %v want %v", q, want)
}

// "Delete Key" on a split row removes the playhead key in every lane's
// channel, as one undo step, and keeps the channels that still have keys.
@(test)
test_delete_key_on_a_split_row_removes_every_lane_key :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	arm := engine.transform_new("Arm", root)
	_rec_split_position(_rec_clip(doc), {0, 1}, {0.5, 1}, {1, 1.5}, {1, 2}, {3, 4}, {5, 6})
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 1)

	off := offset_of(engine.Transform, position)
	top := s.top
	testing.expect(t, inspector.driven_delete_key(engine.Handle(arm), off, typeid_of([3]f32)), "the key at 1.0 is deleted")
	testing.expect_value(t, s.top, top + 1)
	clip := _rec_clip(doc)
	if !testing.expect_value(t, len(clip.channels), 3) do return
	for l in 0 ..< 3 {
		testing.expectf(t, _key_at(&clip.channels[l], 1) < 0, "lane %d has no key at 1.0", l)
		testing.expect_value(t, len(clip.channels[l].times), 1)
	}
	_, _, keyed := inspector.driven_row_state(engine.Handle(arm), off, typeid_of([3]f32))
	testing.expect(t, !keyed, "no key at 1.0 any more")

	testing.expect(t, undo.apply_undo(s), "undo")
	clip = _rec_clip(doc)
	for l in 0 ..< 3 do testing.expectf(t, _key_at(&clip.channels[l], 1) >= 0, "undo brings lane %d's key back", l)
}

// The clip document counts its changes: a recorded edit and its undo each
// bump Asset_Doc.edits, so a view that derives state from the clip rebuilds.
@(test)
test_record_and_undo_bump_document_edits :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	child := engine.transform_new("Child", root)
	w := engine.ctx_world()
	tr := engine.pool_get(&w.transforms, engine.Handle(child))
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 1)

	start := doc.edits
	sess := undo.edit_session_begin({undo.edit_target_transform(child, &tr.position, typeid_of([3]f32))}, "Move")
	tr.position = {1, 2, 3}
	undo.edit_session_end(&sess)
	if !testing.expect_value(t, len(_rec_clip(doc).channels), 1) do return
	recorded := doc.edits
	testing.expectf(t, recorded > start, "the recorded edit bumps edits: %d then %d", start, recorded)

	testing.expect(t, undo.apply_undo(s), "undo")
	testing.expect_value(t, len(_rec_clip(doc).channels), 0)
	testing.expectf(t, doc.edits > recorded, "the undo bumps edits: %d then %d", recorded, doc.edits)
	undone := doc.edits
	testing.expect(t, undo.apply_redo(s), "redo")
	testing.expectf(t, doc.edits > undone, "the redo bumps edits: %d then %d", undone, doc.edits)
}

// A Scale row on Arm before its split Position row (x and y channels): a
// recorded position edit keys the x and y channels at the playhead and leaves
// the Scale row and the channel count as they were.
@(test)
test_record_split_position_beside_scale_keys_only_position :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	arm := engine.transform_new("Arm", root)
	w := engine.ctx_world()
	tr := engine.pool_get(&w.transforms, engine.Handle(arm))
	tr.position = {1, 2, 3}
	tr.scale = {1, 1, 1}
	clip := _rec_clip(doc)
	_rec_add_row(clip, {target = "Arm", path = .Scale}, {0}, {{1, 1, 1, 0}})
	_rec_add_row(clip, {target = "Arm", path = .Position, lanes_off = {1, 2}}, {0}, {{1, 0, 0, 0}})
	_rec_add_row(clip, {target = "Arm", path = .Position, lanes_off = {0, 2}}, {0}, {{0, 2, 0, 0}})
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 1)

	before := s.top
	sess := undo.edit_session_begin({undo.edit_target_transform(arm, &tr.position, typeid_of([3]f32))}, "Move")
	tr.position = {4, 5, 3}
	undo.edit_session_end(&sess)

	clip = _rec_clip(doc)
	if !testing.expect_value(t, len(clip.channels), 3) do return
	scl := &clip.channels[0]
	testing.expect_value(t, scl.path, anim.Animation_Path.Scale)
	testing.expect_value(t, len(scl.times), 1)
	testing.expect_value(t, _key_at(scl, 1), -1)
	want := [2]f32{4, 5}
	for l in 0 ..< 2 {
		ch := &clip.channels[1 + l]
		testing.expect_value(t, ch.path, anim.Animation_Path.Position)
		at := _key_at(ch, 1)
		testing.expectf(t, at >= 0, "lane %d has a key at the playhead", l)
		if at >= 0 do testing.expect_value(t, ch.values.([dynamic][4]f32)[at][l], want[l])
	}
	testing.expect_value(t, tr.position, [3]f32{1, 2, 3})
	testing.expect_value(t, s.top, before + 1)
}

// --- Review fixes ------------------------------------------------------------------------

// A gizmo turn of y from 170 to 190 degrees recorded into an Euler row keys
// y near 190, the angles nearest the row's angles at the playhead, not the
// plain decomposition (-170 or 180/-10/180), which would spin the curve back.
@(test)
test_record_rotation_unwinds_toward_the_row :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	arm := engine.transform_new("Arm", root)
	w := engine.ctx_world()
	tr := engine.pool_get(&w.transforms, engine.Handle(arm))
	tr.rotation = {0, 0, 0, 1}
	_rec_add_row(_rec_clip(doc), {target = "Arm", path = .Euler}, {0, 1}, {{0, 0, 0, 0}, {0, 170, 0, 0}})
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 2)

	sess := undo.edit_session_begin({undo.edit_target_transform(arm, &tr.rotation, typeid_of([4]f32))}, "Rotate")
	tr.rotation = anim.animation_quat_from_euler({0, 190, 0})
	undo.edit_session_end(&sess)

	clip := _rec_clip(doc)
	if !testing.expect_value(t, len(clip.channels), 1) do return
	ch := &clip.channels[0]
	at := _key_at(ch, 2)
	if !testing.expect(t, at >= 0, "a key at the playhead") do return
	e := ch.values.([dynamic][4]f32)[at].xyz
	testing.expectf(t, abs(e.x) < 0.05 && abs(e.y - 190) < 0.05 && abs(e.z) < 0.05, "the key holds y near 190, got %v", e)
}

// While a state of the States tree is previewed, Record keys nothing: the
// edit stays a scene edit, and the row state offers no Add Key.
@(test)
test_record_skips_a_state_preview :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	child := engine.transform_new("Child", root)
	w := engine.ctx_world()
	tr := engine.pool_get(&w.transforms, engine.Handle(child))
	tr.position = {0, 0, 0}
	_rec_add_row(_rec_clip(doc), {target = "Child", path = .Position}, {0}, {{0, 0, 0, 0}})
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 1, entry = 1)

	off := offset_of(engine.Transform, position)
	has_row, keyable, _ := inspector.driven_row_state(engine.Handle(child), off, typeid_of([3]f32))
	testing.expect(t, has_row, "the row is still shown")
	testing.expect(t, !keyable, "no Add Key during a state preview")

	before := s.top
	sess := undo.edit_session_begin({undo.edit_target_transform(child, &tr.position, typeid_of([3]f32))}, "Move")
	tr.position = {1, 2, 3}
	undo.edit_session_end(&sess)

	clip := _rec_clip(doc)
	if !testing.expect_value(t, len(clip.channels), 1) do return
	testing.expect_value(t, len(clip.channels[0].times), 1)
	testing.expect_value(t, tr.position, [3]f32{1, 2, 3})
	testing.expect_value(t, s.top, before + 1)
	testing.expect(t, _has_scene_value(s.items[s.top - 1].cmd), "a scene value step")
}

// At 30 fps a playhead paused at 0.51 s keys on frame 15 (0.5 s), and a key
// within half a frame of the playhead's frame takes the edit in place.
@(test)
test_record_keys_on_the_playheads_frame :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	child := engine.transform_new("Child", root)
	arm := engine.transform_new("Arm", root)
	w := engine.ctx_world()
	ctr := engine.pool_get(&w.transforms, engine.Handle(child))
	atr := engine.pool_get(&w.transforms, engine.Handle(arm))
	clip := _rec_clip(doc)
	clip.frame_rate = 30
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 0.51)

	sess := undo.edit_session_begin({undo.edit_target_transform(child, &ctr.position, typeid_of([3]f32))}, "Move")
	ctr.position = {1, 2, 3}
	undo.edit_session_end(&sess)

	clip = _rec_clip(doc)
	if !testing.expect_value(t, len(clip.channels), 1) do return
	ch := &clip.channels[0]
	testing.expect_value(t, len(ch.times), 2)
	testing.expect(t, _key_at(ch, 0.5) >= 0, "the key is on frame 15")
	testing.expect_value(t, _key_at(ch, 0.51), -1)

	// A key at 0.51 s is the key on the playhead's frame (0.5 s).
	_rec_add_row(clip, {target = "Arm", path = .Position}, {0, 0.51, 1}, {{0, 0, 0, 0}, {1, 1, 1, 0}, {2, 2, 2, 0}})
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 0.495)
	sess = undo.edit_session_begin({undo.edit_target_transform(arm, &atr.position, typeid_of([3]f32))}, "Move")
	atr.position = {4, 5, 6}
	undo.edit_session_end(&sess)

	clip = _rec_clip(doc)
	if !testing.expect_value(t, len(clip.channels), 2) do return
	ach := &clip.channels[1]
	testing.expect_value(t, len(ach.times), 3)
	at := _key_at(ach, 0.51)
	testing.expect(t, at >= 0 && ach.values.([dynamic][4]f32)[at].xyz == [3]f32{4, 5, 6}, "the key at 0.51 takes the edit")
	_, _, keyed := inspector.driven_row_state(engine.Handle(arm), offset_of(engine.Transform, position), typeid_of([3]f32))
	testing.expect(t, keyed, "the key at 0.51 counts as the playhead's key")
}

// A split Euler row: a recorded turn that moves y by 10 degrees and x by
// float noise keys only the y channel.
@(test)
test_record_split_euler_ignores_float_noise :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	arm := engine.transform_new("Arm", root)
	w := engine.ctx_world()
	tr := engine.pool_get(&w.transforms, engine.Handle(arm))
	tr.rotation = anim.animation_quat_from_euler({10, 20, 30})
	clip := _rec_clip(doc)
	masks := [3]anim.Channel_Lanes_Off{{1, 2}, {0, 2}, {0, 1}}
	start := [3]f32{10, 20, 30}
	for l in 0 ..< 3 {
		v: [4]f32
		v[l] = start[l]
		_rec_add_row(clip, {target = "Arm", path = .Euler, lanes_off = masks[l]}, {0}, {v})
	}
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 1)

	sess := undo.edit_session_begin({undo.edit_target_transform(arm, &tr.rotation, typeid_of([4]f32))}, "Rotate")
	tr.rotation = anim.animation_quat_from_euler({10.00001, 30, 30})
	undo.edit_session_end(&sess)

	clip = _rec_clip(doc)
	if !testing.expect_value(t, len(clip.channels), 3) do return
	testing.expect_value(t, _key_at(&clip.channels[0], 1), -1)
	testing.expect_value(t, _key_at(&clip.channels[2], 1), -1)
	at := _key_at(&clip.channels[1], 1)
	testing.expect(t, at >= 0, "the y channel has a key at the playhead")
	if at >= 0 do testing.expectf(t, abs(clip.channels[1].values.([dynamic][4]f32)[at].y - 30) < 0.01, "y keys 30, got %v", clip.channels[1].values.([dynamic][4]f32)[at])
}

// The inspector's questions resolve a field once per frame: two asks in one
// frame return the same rows, a row changed in place shows up on the next
// frame, and so does a row added between frames.
@(test)
test_record_field_memo_follows_frames :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	arm := engine.transform_new("Arm", root)
	clip := _rec_clip(doc)
	_rec_add_row(clip, {target = "Arm", path = .Scale}, {0}, {{1, 1, 1, 0}})
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 1, armed = false)

	pos := offset_of(engine.Transform, position)
	scl := offset_of(engine.Transform, scale)
	v3 := typeid_of([3]f32)
	a := animation_editor.animation_record_field_channels(engine.Handle(arm), scl, v3)
	b := animation_editor.animation_record_field_channels(engine.Handle(arm), scl, v3)
	testing.expect_value(t, len(a), 1)
	testing.expect(t, raw_data(a) == raw_data(b), "the second ask in a frame is the memo's answer")
	testing.expect_value(t, len(animation_editor.animation_record_field_channels(engine.Handle(arm), pos, v3)), 0)

	// The Scale row becomes a Position row in place: the next frame sees it.
	clip.channels[0].path = .Position
	gfx.frame_index += 1
	testing.expect_value(t, len(animation_editor.animation_record_field_channels(engine.Handle(arm), pos, v3)), 1)
	testing.expect_value(t, len(animation_editor.animation_record_field_channels(engine.Handle(arm), scl, v3)), 0)

	_rec_add_row(clip, {target = "Arm", path = .Scale}, {0}, {{1, 1, 1, 0}})
	gfx.frame_index += 1
	testing.expect_value(t, len(animation_editor.animation_record_field_channels(engine.Handle(arm), scl, v3)), 1)
}

// Recording into a joined row with y disabled enables y, and every other key
// of the row takes the live y the object showed, so y holds flat instead of
// replaying the stale values the disabled lane kept.
@(test)
test_record_into_a_joined_row_fills_the_disabled_lanes :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	arm := engine.transform_new("Arm", root)
	w := engine.ctx_world()
	tr := engine.pool_get(&w.transforms, engine.Handle(arm))
	tr.position = {1, 2, 3}
	_rec_add_row(_rec_clip(doc), {target = "Arm", path = .Position, lanes_off = {1}}, {0, 1}, {{7, 99, 9, 0}, {8, 98, 9, 0}})
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 1)

	sess := undo.edit_session_begin({undo.edit_target_transform(arm, &tr.position, typeid_of([3]f32))}, "Move")
	tr.position = {5, 2, 3}
	undo.edit_session_end(&sess)

	clip := _rec_clip(doc)
	if !testing.expect_value(t, len(clip.channels), 1) do return
	ch := &clip.channels[0]
	testing.expect_value(t, ch.lanes_off, anim.Channel_Lanes_Off{})
	vals := ch.values.([dynamic][4]f32)
	k0 := _key_at(ch, 0)
	k1 := _key_at(ch, 1)
	if !testing.expect(t, k0 >= 0 && k1 >= 0, "keys at 0 and 1") do return
	testing.expect_value(t, vals[k1].xyz, [3]f32{5, 2, 3})
	testing.expect_value(t, vals[k0].xyz, [3]f32{7, 2, 9})
}

// --- Lanes the clip leaves to the object ---------------------------------------------

// A Volume size row on "Box" under "Root" animating x only: 1 at 0 s, 3 at 1 s.
@(private = "file")
_rec_size_x_row :: proc(clip: ^anim.AnimationClip) {
	guid := uuid.to_string(engine.get_guid_by_typeid(engine.Volume), context.temp_allocator)
	_rec_add_row(clip, {target = "Box", component = guid, field = "size", lanes_off = {1, 2}}, {0, 1}, {{1, 0, 0, 0}, {3, 0, 0, 0}})
}

// The provider names the lanes no row animates: a masked vector field, a
// masked Position row, a masked Euler row read as angles. A quaternion and a
// row with every lane are driven whole.
@(test)
test_driven_provider_names_the_objects_own_lanes :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	box := engine.transform_new("Box", root)
	_, vp := engine.transform_add_comp(box, .Volume)
	vol := cast(^engine.Volume)vp
	vol.size = {5, 6, 7}
	clip := _rec_clip(doc)
	_rec_size_x_row(clip)
	_rec_add_row(clip, {target = "Box", path = .Position, lanes_off = {0, 2}}, {0}, {{0, 2, 0, 0}})
	_rec_add_row(clip, {target = "Box", path = .Euler, lanes_off = {0, 1}}, {0}, {{0, 0, 30, 0}})
	_rec_add_row(clip, {target = "Box", path = .Scale}, {0}, {{2, 2, 2, 0}})
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 0.5, armed = false)

	size: [3]f32
	driven, _, own := inspector.driven_provider(_rec_comp(box, .Volume), offset_of(engine.Volume, size), typeid_of([3]f32), &size)
	testing.expect(t, driven, "the size is driven")
	testing.expect_value(t, own, inspector.Driven_Lanes{1, 2})
	testing.expect_value(t, size, [3]f32{2, 6, 7})

	pos: [3]f32
	_, _, own = inspector.driven_provider(engine.Handle(box), offset_of(engine.Transform, position), typeid_of([3]f32), &pos)
	testing.expect_value(t, own, inspector.Driven_Lanes{0, 2})

	e: [3]f32
	_, _, own = inspector.driven_provider(engine.Handle(box), offset_of(engine.Transform, rotation), typeid_of([3]f32), &e)
	testing.expect_value(t, own, inspector.Driven_Lanes{0, 1})
	q: [4]f32
	_, _, own = inspector.driven_provider(engine.Handle(box), offset_of(engine.Transform, rotation), typeid_of([4]f32), &q)
	testing.expect_value(t, own, inspector.Driven_Lanes{})

	scl: [3]f32
	_, _, own = inspector.driven_provider(engine.Handle(box), offset_of(engine.Transform, scale), typeid_of([3]f32), &scl)
	testing.expect_value(t, own, inspector.Driven_Lanes{})
}

@(private = "file")
_write_size_xy :: proc(field_ptr: rawptr) {
	v := cast(^[3]f32)field_ptr
	v.x = 9 // driven: dropped in preview
	v.y = 8 // the object's own
}

@(private = "file")
_drag_size :: proc(box: engine.Transform_Handle, vol: ^engine.Volume) {
	undo.push_component_owner(_rec_comp(box, .Volume))
	defer undo.pop_owner()
	h := common.Row_Harness{
		field_ptr = &vol.size,
		field_tid = typeid_of([3]f32),
		offset    = offset_of(engine.Volume, size),
		label     = "size",
	}
	common.row_replay(&h, []common.Frame{
		common.frame_press(_write_size_xy),
		common.frame_drag(_write_size_xy),
		common.frame_release(),
	})
}

// In preview an edit of a lane the clip does not drive changes the object, as
// an ordinary row edit: the lane takes the value, the driven lane keeps the
// object's own value, the clip is untouched, and the gesture is one scene
// undo step that undo takes back. While recording the same edit keys the
// clip, as every edit does, and the object keeps its value.
@(test)
test_driven_row_edits_the_objects_own_lanes :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	doc := _rec_open_clip(t)
	defer _rec_close()
	if doc == nil do return

	root := engine.transform_new("Root")
	box := engine.transform_new("Box", root)
	_, vp := engine.transform_add_comp(box, .Volume)
	vol := cast(^engine.Volume)vp
	vol.size = {5, 6, 7}
	_rec_size_x_row(_rec_clip(doc))
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 0.5, armed = false)

	before := s.top
	_drag_size(box, vol)
	testing.expect_value(t, vol.size, [3]f32{5, 8, 7})
	testing.expect_value(t, s.top, before + 1)
	testing.expect(t, _has_scene_value(s.items[s.top - 1].cmd), "a scene value step")
	ch := &_rec_clip(doc).channels[0]
	testing.expect_value(t, len(ch.times), 2)
	testing.expect_value(t, ch.lanes_off, anim.Channel_Lanes_Off{1, 2})
	testing.expect(t, undo.apply_undo(s), "undo")
	testing.expect_value(t, vol.size, [3]f32{5, 6, 7})

	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 0.5, armed = true)
	before = s.top
	_drag_size(box, vol)
	testing.expect_value(t, vol.size, [3]f32{5, 6, 7})
	testing.expect_value(t, s.top, before + 1)
	testing.expect(t, !_has_scene_value(s.items[s.top - 1].cmd), "no scene value step")
	ch = &_rec_clip(doc).channels[0]
	at := _key_at(ch, 0.5)
	testing.expect(t, at >= 0, "a key at the playhead")
	if at >= 0 do testing.expect_value(t, ch.values.([dynamic][4]f32)[at].xyz, [3]f32{9, 8, 7})
	testing.expect_value(t, ch.lanes_off, anim.Channel_Lanes_Off{})
}

// --- The window's lock ---------------------------------------------------------------

// Locked, the window keeps its animated object whatever is selected, and
// unlocked it follows the selection again. The lock is saved as the object's
// scene asset and local id and taken up again after a restart once the scene
// is loaded. A locked object that is deleted releases the lock.
@(test)
test_animation_view_lock_keeps_its_object_and_survives_a_restart :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)
	defer animation_editor.animation_view_lock_set(false)
	defer animation_editor.animation_record_reset()
	defer engine.inspector_set_inspected_selection({})

	scene := engine.sm_scene_get_active()
	if !testing.expect(t, scene != nil, "a scene is active") do return
	scene.asset_guid = engine.Asset_GUID{0 = 0xA7, 15 = 0x02}
	a := engine.transform_new("A")
	engine.transform_add_comp(a, .Animation)
	b := engine.transform_new("B")
	engine.transform_add_comp(b, .Animation)

	engine.inspector_set_inspected_selection(a)
	testing.expect_value(t, animation_editor.animation_view_target(), a)
	animation_editor.animation_record_arm(a, {}, 0, armed = false)
	animation_editor.animation_view_lock_set(true)
	testing.expect(t, animation_editor.animation_view_locked(), "locked")

	engine.inspector_set_inspected_selection(b)
	testing.expect_value(t, animation_editor.animation_view_target(), a)

	// A restart: the live lock goes, the saved one comes back once found.
	animation_editor.animation_view_lock_forget_for_test()
	testing.expect_value(t, animation_editor.animation_view_target(), a)
	testing.expect(t, animation_editor.animation_view_locked(), "locked again after the restart")

	animation_editor.animation_view_lock_set(false)
	testing.expect_value(t, animation_editor.animation_view_target(), b)

	// Deleting the locked object releases the lock.
	animation_editor.animation_record_arm(a, {}, 0, armed = false)
	animation_editor.animation_view_lock_set(true)
	engine.transform_destroy(a)
	testing.expect_value(t, animation_editor.animation_view_target(), b)
	testing.expect(t, !animation_editor.animation_view_locked(), "the lock went with its object")
}

