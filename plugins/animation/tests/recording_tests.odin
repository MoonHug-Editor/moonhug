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
import animation_editor "moonhug:packages/animation/editor"
import common "moonhug:tests/common"

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
	if at >= 0 do testing.expect_value(t, ch.values[at].x, 5)
	start := _key_at(ch, 0)
	testing.expect(t, start >= 0, "the new row starts at the clip start")
	if start >= 0 do testing.expect_value(t, ch.values[start].x, 1)
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
		testing.expect(t, at >= 0 && clip.channels[0].values[at].x == 5, "redo restores the key")
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
	testing.expect(t, at >= 0 && ch.values[at].xyz == [3]f32{1, 2, 3}, "the key at the playhead holds the dragged position")
	testing.expect_value(t, tr.position, [3]f32{0, 0, 0})
	testing.expect_value(t, s.top, before + 1)
	testing.expect(t, !_has_scene_value(s.items[s.top - 1].cmd), "no scene value step")
}

// A string field cannot be keyed: the edit stays a scene edit and the window
// says why.
@(test)
test_record_leaves_a_string_edit_alone :: proc(t: ^testing.T) {
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

	testing.expect_value(t, cam.slot, "Main")
	testing.expect_value(t, len(_rec_clip(doc).channels), 0)
	testing.expect_value(t, s.top, before + 1)
	testing.expect(t, _has_scene_value(s.items[s.top - 1].cmd), "a scene value step")
	testing.expect_value(t, animation_editor.animation_record_note(), "Cannot key slot: string is not animatable")
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
	for v in values do append(&c.values, v)
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
	driven, editable = inspector.driven_provider(owner, offset, typeid_of(f32), &v)
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
	driven, editable := inspector.driven_provider(engine.Handle(arm), offset_of(engine.Transform, position), typeid_of([3]f32), &pos)
	testing.expect(t, driven && !editable, "the position is driven, read-only")
	testing.expect_value(t, pos, [3]f32{1, 2, 3})

	scale: [3]f32
	driven, _ = inspector.driven_provider(engine.Handle(arm), offset_of(engine.Transform, scale), typeid_of([3]f32), &scale)
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
	testing.expect_value(t, ch.values[1].x, 9)
	testing.expect_value(t, s.top, before + 1)
	testing.expect(t, undo.apply_undo(s), "undo")
	ch = &_rec_clip(doc).channels[0]
	testing.expect_value(t, ch.values[1].x, 3)

	// No key at the playhead: one is added between the others.
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 0.5, armed = false)
	before = s.top
	animation_editor.animation_record_key_row(0, {4, 0, 0, 0})
	ch = &_rec_clip(doc).channels[0]
	testing.expect_value(t, len(ch.times), 3)
	at := _key_at(ch, 0.5)
	testing.expect_value(t, at, 1)
	if at >= 0 do testing.expect_value(t, ch.values[at].x, 4)
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
	if at >= 0 do testing.expect_value(t, ch.values[at].x, 5)
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
	driven, editable := inspector.driven_provider(engine.Handle(arm), offset_of(engine.Transform, scale), typeid_of([3]f32), &shown)
	testing.expect(t, driven && editable, "the scale is driven and editable")
	testing.expect_value(t, shown, [3]f32{2, 2, 2})

	before := s.top
	one := [3]f32{1, 1, 1}
	ok := inspector.driven_commit(engine.Handle(arm), offset_of(engine.Transform, scale), typeid_of([3]f32), &one)
	testing.expect(t, ok, "the commit keys the field")

	ch := &_rec_clip(doc).channels[0]
	at := _key_at(ch, 1)
	testing.expect(t, at >= 0, "a key at the playhead")
	if at >= 0 do testing.expect_value(t, ch.values[at].xyz, [3]f32{1, 1, 1})
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
	if at >= 0 do testing.expect_value(t, ch.values[at].x, 1)
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
	q := ch.values[at]
	testing.expect(t, abs(linalg.length(q) - 1) < 1e-4, "the key is a unit quaternion")
	e := engine.quat_to_euler_xyz(q)
	EPS :: f32(0.01)
	testing.expectf(t, abs(e.x) < EPS && abs(e.y - 90) < EPS && abs(e.z) < EPS, "the key reads back as (0, 90, 0), got %v", e)
}
