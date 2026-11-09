package animation_editor

// Animation window — clip authoring on the PlayableGraph scrub path
// (plugins/animation/docs/windows/AnimationWindow.md): scrub preview plus dopesheet and curve
// editing for the clips on the selected object's Animation component.
//
// PREVIEW (step 5): never leaks into saved data. Each frame:
//   1. the window UI sets the scrub state (clip, time, on/off),
//   2. animation_preview_apply refreshes the binding defaults from the live
//      transforms, evaluates the clip at the scrub time and applies the pose,
//   3. the scene and Game windows render the posed world,
//   4. animation_preview_restore writes the defaults back.
// Outside that render window the world holds authored values, so saves and
// undo are untouched by construction — there is no preview state to revert
// when preview ends, the target dies or its scene unloads. The inspector
// shows the preview's values through inspector.driven_provider (record.odin).
//
// EDITING (step 6): keyframe operations edit the clip's ASSET DOCUMENT (the
// session registry the project inspector uses), so every operation is a
// whole-document undo step re-found by guid. Edits sync into the engine's
// clip cache (animation_clip_preview) the way material edits live-preview —
// that cache is what the scrub preview and any playing Animation component
// sample. Save writes the document to the .anim file. Unsaved edits revert
// next editor run, same as materials.

import "base:runtime"
import "core:encoding/uuid"
import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:strings"
import im "moonhug:external/odin-imgui"
import engine "moonhug:packages/engine"
import gfx "moonhug:libs/gfx"
import anim "moonhug:packages/animation"
import "moonhug:editor/inspector"
import "moonhug:editor/session"
import "moonhug:editor/undo"
import "moonhug:editor/preview"
import "moonhug:editor/widgets"
import wnd "moonhug:editor/window"
import "moonhug:editor/keymap"
import "moonhug:editor/icons"

@(private) _ANIM_ROW_H :: f32(20)
@(private) _ANIM_PAD_X :: f32(10) // time gutter inside the canvas
@(private) _ANIM_HIT :: f32(6)    // key hit-test radius
@(private) _ANIM_ARROW_W :: f32(10) // an Object row's collapse arrow
// Missing-binding yellow: a row whose target, component or field no longer
// resolves. It samples but never applies.
@(private) _ANIM_WARN_COL :: im.Vec4{0.95, 0.83, 0.30, 1}

// Curve colors per value component (x red, y green, z blue, w grey).
@(private)
_ANIM_COMP_COLS :: [4]im.Vec4{
	{0.91, 0.35, 0.35, 1},
	{0.42, 0.85, 0.42, 1},
	{0.40, 0.58, 1.00, 1},
	{0.75, 0.75, 0.75, 1},
}

// One key in the sheet: which channel row, which key in it.
@(private)
_Key_Ref :: struct {
	ch:  int,
	key: int,
}

@(private = "file")
_Anim_Mode :: enum {
	Dopesheet,
	Curves,
}

@(private)
_pv: struct {
	active:  bool, // preview on: the world renders the scrubbed pose
	applied: bool, // pose applied this frame, restore pending
	owner:   engine.Transform_Handle, // the Animation component's transform
	clip:    engine.PPtr,
	time:    f32,
	graph:     anim.Playable_Graph, // the component's FULL authored graph
	node:      anim.Playable_Handle, // the scrubbed clip's node (weight 1)
	graph_sig: u64, // authored clip set the graph was built from
	rows_sig:  u64, // the shown clip's rows and lanes the binding holds (_pv_rows_sig)
	ready:     bool,

	// STATE mode: the States tree is previewing an authored state rather than
	// the window scrubbing a clip. Both drive this one preview, so they cannot
	// pose the object at the same time — entry 0 means clip-scrub mode.
	//
	// `entry_clock` is seconds for a clip state and a normalized phase for a
	// blend, matching what each kind runs on at playback.
	entry:       i32,
	entry_kids:  [dynamic]anim.Animation_Blend_Child, // a blend's children, sorted by position
	entry_top:   anim.Playable_Handle, // what hangs from the layer mixer
	entry_layer: anim.Playable_Handle,
	entry_clock: f32,
	entry_done:  bool,

	playing:   bool, // transport running: time advances every frame
	recording: bool, // armed: an edit of an animatable field keys it at the playhead (record.odin)

	// The document edit count and guid the clip cache holds (_animation_frame
	// pushes the document into the cache when they differ).
	synced_edits: u64,
	synced_guid:  engine.Asset_GUID,
}

ANIMATION_WINDOW :: "Animation"

// One Animation copy's own state: how it shows the clip. The clip, the
// playhead and the transport are the preview's (_pv), shared by every copy,
// since the world holds one pose.
@(private)
_Anim_Window :: struct {
	left_w:    f32, // property column width, dragged via the pane splitter
	// The sheet model derived from the clip (sheet_cache.odin): rows, groups
	// and resolved field metadata, rebuilt when the document's edit count
	// or window_gen changes. Models replaced this frame wait in sheets_old
	// until the next frame, so a slice taken before an edit stays readable.
	sheet:      _Sheet,
	sheets_old: [dynamic]_Sheet,
	window_gen:   u64, // bumped by collapse and expand toggles
	// The selection in a form that survives edits: the stable channel key
	// and lane set, and the key index. Taken when the selection changed
	// (sel_dirty) before an edit, restored after the sheet rebuilds.
	sel_snap:    [dynamic]_Sel_Snap,
	sel_primary: int, // index into sel_snap, -1 for none
	sel_dirty:   bool,
	// Set by the sheet each frame: the pointer is over the time canvas, where
	// the wheel zooms. Read by the body child, which scrolls on the wheel only
	// when it is false.
	over_canvas: bool,
	mode:      _Anim_Mode,
	sel_ch:    int, // selected channel row, -1 = none
	sel_key:   int, // PRIMARY selected key in sel_ch, -1 = none
	// Every selected key, primary included. A drag moves all of them and
	// Delete removes all of them. The primary is the key the value footer
	// edits.
	sel:       [dynamic]_Key_Ref,
	// The keys of sel as a set, so membership is one lookup
	// (window_selection.odin). On the default allocator, rebuilt when stale:
	// sel_rev counts the selection changes it does not follow, sel_stamp is
	// the state it was built from.
	sel_set:   map[_Key_Ref]bool,
	sel_rev:   u64,
	sel_stamp: _Sel_Set_Stamp,
	drag_key:  bool, // canvas key drag in progress (undo snapshot open)
	drag_comp: int,  // curves: value component the drag edits, -1 = time only
	drag_from: f32,  // time under the cursor when the drag began
	drag_press: im.Vec2, // mouse at the press: a drag moves keys only past _ANIM_DRAG_PX
	drag_live: bool, // the press moved far enough to be a drag, not a click
	drag_t0:   [dynamic]f32, // each selected key's time then, parallel to sel
	// Curves: a tangent handle drag in progress (undo session open), on key
	// tan_key of the selected channel, lane tan_comp, the out handle when
	// tan_out, else the in handle.
	drag_tan:  bool,
	tan_key:   int,
	tan_comp:  int,
	tan_out:   bool,
	// The euler angles of a quaternion Rotation row or key while one of its
	// fields is active (window_footer.odin, window_rows.odin): channel euler_ch,
	// key euler_key (-1 for the row fields at the playhead), last active on
	// imgui frame euler_frame.
	euler_buf:   [3]f32,
	euler_ch:    int,
	euler_key:   int,
	euler_frame: i32,
	// Box select in progress, and where it started (screen space).
	box:       bool,
	box_from:  im.Vec2,
	// Time-axis view, the sequencer's model: zoom is a multiple of the scale
	// that fits the whole clip, so 1 is "fit" and pan is then pinned to 0.
	// pan is the time at the canvas's left edge.
	zoom:      f32,
	pan:       f32,
	wheel:     widgets.Wheel_Lock, // one wheel axis per gesture
	// Targets whose Object row is collapsed (sheet_rows.odin). Keys are clones
	// under the default allocator, freed with the window. Not persisted.
	collapsed: map[string]bool,
	// Vector rows whose Lane rows show, by sheet_channel_key. Keys are clones
	// under the default allocator, freed with the window. Not persisted.
	expanded:  map[string]bool,
	// The Object row path field (retargeting). path_target is the target being
	// edited and ctx_target the Object row the context menu opened on, both
	// clones under the default allocator. path_wait counts the frames left for
	// the field to take focus, 0 once it has it.
	path_edit:   bool,
	path_target: string,
	path_buf:    [256]u8,
	path_wait:   int,
	ctx_target:  string,
}

_ANIM_WINDOW_INIT :: _Anim_Window{left_w = 300, sel_ch = -1, sel_key = -1, euler_frame = -1}

// The copy being drawn, and outside a draw the copy clicked in last. With no
// copy open it points at a spare state, so a write lands nowhere.
@(private)
_av: ^_Anim_Window = &_av_none

@(private)
_av_none := _ANIM_WINDOW_INIT

@(private)
_anim_window :: proc(w: ^wnd.Window) -> ^_Anim_Window {
	return wnd.state(w, _ANIM_WINDOW_INIT)
}

@(private = "file")
_anim_window_free :: proc(av: ^_Anim_Window) {
	context.allocator = runtime.default_allocator()
	_sheet_free(&av.sheet)
	for &old in av.sheets_old do _sheet_free(&old)
	delete(av.sheets_old)
	av.sheets_old = nil
	_sel_snap_clear(av)
	delete(av.sel_snap)
	av.sel_snap = nil
	delete(av.sel)
	delete(av.sel_set)
	delete(av.drag_t0)
	for k in av.collapsed do delete(k)
	delete(av.collapsed)
	for k in av.expanded do delete(k)
	delete(av.expanded)
	delete(av.path_target)
	delete(av.ctx_target)
	av.sel = nil
	av.sel_set = nil
	av.drag_t0 = nil
	av.collapsed = nil
	av.expanded = nil
	av.path_edit = false
	av.path_target = ""
	av.ctx_target = ""
}

// Replaces a window-owned string with a clone of `s`.
@(private)
_pv_view_str_set :: proc(dst: ^string, s: string) {
	delete(dst^, runtime.default_allocator())
	dst^ = strings.clone(s, runtime.default_allocator())
}

animation_window_closed :: proc(w: ^wnd.Window) {
	av := (^_Anim_Window)(w.data)
	if av == nil do return
	if _av == av do _av = &_av_none
	_anim_window_free(av)
	free(av, runtime.default_allocator())
	w.data = nil
}

@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
animation_preview_install :: proc() {
	preview.register({apply = animation_preview_apply, restore = animation_preview_restore})
	preview.register_frame({frame = _animation_windows_frame})
}

// The preview's own frame, once per frame before the windows draw: with an
// Animation copy open it follows the target and runs the transport, whether
// or not a copy is visible, and with none open the preview ends.
@(private = "file")
_animation_windows_frame :: proc() {
	if wnd.is_open(ANIMATION_WINDOW) {
		_animation_frame()
	} else {
		animation_preview_stop()
	}
}

@(phase={key=engine.Phase.EditorShutdown, order=1, mode=Editor})
animation_windows_shutdown :: proc() {
	shutdown_animation_window()
	shutdown_animation_inspector()
}

shutdown_animation_window :: proc() {
	_pv_teardown()
	_record_note_clear()
	_anim_window_free(&_av_none)
}

// Closing the last Animation copy ends the preview.
animation_preview_stop :: proc() {
	_pv_preview_off()
}

// Stop previewing, and stop everything that only makes sense while previewing.
// A running transport with nothing posed is a playhead sweeping the sheet for
// no reason, and it surprises you later: turning preview back on resumes
// mid-clip, and the button sat on Pause the whole time. A previewed STATE is
// the same — it poses through this preview, so it ends with it.
@(private)
_pv_preview_off :: proc() {
	_pv.active = false
	_pv.playing = false
	_pv.recording = false
	_pv.entry = 0
	_record_note_clear()
}

@(private)
_pv_teardown :: proc() {
	if _pv.ready {
		anim.playable_graph_destroy(&_pv.graph)
	}
	_pv.ready = false
	_pv.node = {}
	// These name nodes in the graph just destroyed.
	clear(&_pv.entry_kids)
	_pv.entry_top = {}
	_pv.entry_layer = {}
}

// The Animation component the window targets: on the locked object or the
// selection (window_lock.odin), or its nearest ancestor, so selecting a child
// bone keeps the window on the animated root. The Playable Graph visualizer
// follows the selection by the same ancestor rule, without the lock.
@(private)
_pv_target :: proc() -> (owner: engine.Transform_Handle, a: ^anim.Animation) {
	w := engine.ctx_world()
	// The locked object, or the selection (window_lock.odin).
	tH := _anim_lock_target()
	for engine.pool_valid(&w.transforms, engine.Handle(tH)) {
		if _, comp := engine.transform_get_comp(tH, anim.Animation); comp != nil {
			return tH, comp
		}
		t := engine.pool_get(&w.transforms, engine.Handle(tH))
		if t == nil do break
		tH = engine.Transform_Handle(t.parent.handle)
	}
	return {}, nil
}

// Every clip reachable from the component: the default clip plus every clip
// entry on every layer, blend children included — a clip inside a blend is
// still a clip you edit here. Deduplicated, temp-allocated.
@(private = "file")
_pv_clips :: proc(a: ^anim.Animation) -> []engine.PPtr {
	clips := make([dynamic]engine.PPtr, context.temp_allocator)
	_pv_clips_add(&clips, a.clip)
	for &l in a.layers {
		for &e in l.entries {
			if c, is_clip := e.kind.(anim.Animation_Entry_Clip); is_clip do _pv_clips_add(&clips, c.clip)
		}
	}
	return clips[:]
}

@(private = "file")
_pv_clips_add :: proc(clips: ^[dynamic]engine.PPtr, g: engine.PPtr) {
	if g == {} do return
	for c in clips^ {
		if c == g do return
	}
	append(clips, g)
}

// Shared with the Playable Graph visualizer's clip node labels.
@(private)
_pv_clip_name :: proc(g: engine.PPtr) -> string {
	if path, ok := engine.asset_db_get_path(uuid.Identifier(g.guid)); ok {
		if g.local_id == 0 do return filepath.stem(path)
		for c in engine.mesh_clips(g.guid) do if c.id == g.local_id do return fmt.tprintf("%s / %s", filepath.stem(path), c.name)
	}
	return "(missing clip)"
}

// --- Document access and undo --------------------------------------------------------

// The selected clip's asset document — the edit target. Refetched every frame:
// undo/redo swaps the document payload, so pointers never survive a frame.
// A clip inside a model is baked from the model and has no document: it comes
// back as the cached clip with a nil doc, which the window shows read-only.
@(private)
_pv_doc :: proc() -> (doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip) {
	if _pv.clip == {} do return nil, nil
	if _pv.clip.local_id != 0 {
		c, _ := anim.animation_clip_load(_pv.clip)
		return nil, c
	}
	path, ok := engine.asset_db_get_path(uuid.Identifier(_pv.clip.guid))
	if !ok do return nil, nil
	d := inspector.asset_doc_get(path)
	if d == nil || d.data.id != typeid_of(anim.AnimationClip) do return nil, nil
	return d, cast(^anim.AnimationClip)d.data.data
}

// The Animation window edits a document across frames (dragging a keyframe), so
// its edit is a session like any other — opened when the gesture starts, closed
// when it ends. See docs/core/Undo.md.
@(private)
_pv_session: undo.Edit_Session

// One whole-document undo step: the session captures the document before the
// mutation and records the result after. Drags open on press and close on
// release, mutating in between.
@(private)
_pv_edit_begin :: proc(doc: ^inspector.Asset_Doc) {
	// The selection in its stable form, while the indices still hold.
	if doc != nil && doc.data.id == typeid_of(anim.AnimationClip) do _pv_sel_snapshot(cast(^anim.AnimationClip)doc.data.data)
	// Idempotent: the drag calls this on activation, and a second call while the
	// same gesture is open would otherwise capture the already-edited value.
	if undo.edit_session_active(&_pv_session) do return
	_pv_session = undo.edit_session_begin(
		{undo.edit_target_asset(doc.guid, doc.data.id)}, "Animation Edit")
}

@(private)
_pv_edit_commit :: proc(doc: ^inspector.Asset_Doc) {
	if _pv_edit_held == 0 do undo.edit_session_end(&_pv_session)
	_pv_mark_edited(doc)
	// The sheet and the selection follow the edit at once, so nothing later
	// this frame reads channel indices from before it.
	if _av != &_av_none && doc.data.id == typeid_of(anim.AnimationClip) do _pv_sheet(doc, cast(^anim.AnimationClip)doc.data.data)
}

// How many callers hold the session open: a gesture that runs several
// keyframe operations that each open and commit (recording a new row is a
// channel plus a key, a row value drag spans frames). While it is above
// zero _pv_edit_commit leaves the session open, and the caller whose release
// brings it to zero commits once at the end. Holds nest, so a record inside
// a row value drag does not end the drag's session.
@(private)
_pv_edit_held: int

@(private)
_pv_edit_hold :: proc() {
	_pv_edit_held += 1
}

@(private)
_pv_edit_release :: proc() {
	assert(_pv_edit_held > 0, "animation: a session release matches a hold")
	_pv_edit_held -= 1
}

@(private)
_pv_mark_edited :: proc(doc: ^inspector.Asset_Doc) {
	inspector.asset_doc_mark_edited(doc)
}

// --- Window ---------------------------------------------------------------------------

// The target and the transport: retargeting follows the selection and the
// playhead advances.
@(private = "file")
_animation_frame :: proc() {
	// A row value gesture whose field stopped being drawn mid-drag (the window
	// closed) is over: nothing is active any more.
	if _pv_row_gesture && !im.IsAnyItemActive() do _pv_row_gesture_end()

	owner, a := _pv_target()
	if a == nil {
		_pv_preview_off()
		return
	}
	// Retarget follows selection: the old target's graph and binding
	// belong to the old owner.
	if owner != _pv.owner {
		_pv_teardown()
		_pv_deselect_all()
		_pv.owner = owner
	}

	clips := _pv_clips(a)
	if len(clips) == 0 {
		_pv_preview_off()
		return
	}
	in_list := false
	for c in clips {
		if c == _pv.clip do in_list = true
	}
	if !in_list {
		_pv_teardown()
		_pv_deselect_all()
		_pv.clip = clips[0]
		_pv.time = 0
	}

	doc, clip := _pv_doc()
	// The document's edits reach the engine cache the preview samples from,
	// every frame, whether or not an Animation window is shown: recording
	// from the inspector keeps posing from the current keys.
	if doc != nil && clip != nil && (doc.edits != _pv.synced_edits || doc.guid != _pv.synced_guid) {
		anim.animation_clip_preview(engine.PPtr{guid = doc.guid}, clip^)
		_pv.synced_edits = doc.edits
		_pv.synced_guid = doc.guid
	}
	length := clip != nil ? max(clip.length, 0.0001) : 0.0001
	_pv_advance(clip, length)
}

@(editor_window={id="Animation", title="Animation", icon="ANIMATION", closed=animation_window_closed, lock="shared"})
animation_window_draw :: proc(w: ^wnd.Window) {
	_av = _anim_window(w)
	defer {
		last := wnd.last(ANIMATION_WINDOW)
		_av = _anim_window(last) if last != nil else &_av_none
	}

	// Locked to an object that is not here now: say so (the editor's
	// window_lock.odin).
	if session.window_lock_missing_note(w.key) do return
	_, a := _pv_target()
	if a == nil {
		im.TextDisabled("Select an object with an Animation component.")
		return
	}
	clips := _pv_clips(a)
	if len(clips) == 0 {
		im.TextDisabled("The Animation component has no clips.")
		return
	}

	doc, clip := _pv_doc()
	length := clip != nil ? max(clip.length, 0.0001) : 0.0001

	// Read-only is a clip inside a model. A missing or unreadable .anim has no
	// document either, and the edit guards stop on that, but it is not marked
	// Read-Only: the sheet says the clip is missing.
	_pv_draw_toolbar(clip, length, read_only = _pv.clip.local_id != 0)
	_record_draw_note()

	if clip == nil {
		// The picker still draws, so a broken clip is not a dead end.
		_pv_draw_sheet_header(doc, nil, clips, _av.left_w)
		im.TextDisabled("The clip is missing or unreadable.")
		return
	}
	// The sheet model for this clip and document state. An undo since the
	// selection was made rebuilds it and maps the selection over.
	_sheets_old_free(_av)
	_pv_sheet(doc, clip)
	_pv_sel_prune(clip)

	// The sheet, then the view tabs under it: the tabs belong to the sheet,
	// not to the transport, so they sit at its bottom edge.
	footer := _pv_sel_valid(clip)
	tabs_h := im.GetFrameHeight() + im.GetStyle().ItemSpacing.y
	body_h := -(tabs_h + (footer ? im.GetFrameHeight() + 8 : 0))
	// NoScrollWithMouse: over the time canvas the wheel ZOOMS, and imgui
	// scrolling this child at the same time made the sheet drift under the
	// cursor mid-zoom. The property-name column has no such claim, so the wheel
	// there scrolls by hand below — the sequencer splits its two halves the
	// same way.
	im.BeginChild("##anim_body", im.Vec2{0, body_h}, {.Borders}, {.NoScrollWithMouse})
	_pv_draw_sheet(doc, clip, clips)
	if !_av.over_canvas && im.IsWindowHovered(im.HoveredFlags_ChildWindows) {
		if wheel := im.GetIO().MouseWheel; wheel != 0 {
			im.SetScrollY(im.GetScrollY() - wheel * im.GetTextLineHeightWithSpacing() * 3)
		}
	}
	im.EndChild()
	_pv_draw_mode_tabs()

	// The keys are the "Animation" keymap's commands (the end of this file).

	if footer && _pv_sel_valid(clip) {
		_pv_draw_key_footer(doc, clip)
	}
}

@(private = "file")
_pv_draw_toolbar :: proc(clip: ^anim.AnimationClip, length: f32, read_only: bool) {
	fps := anim.animation_clip_frame_rate(clip)

	// Preview toggle. The pop must match the state at push time — the click
	// flips _pv.active in between.
	tinted := _pv.active
	if tinted do im.PushStyleColorImVec4(.Button, im.GetStyleColorVec4(.ButtonActive)^)
	if im.Button("Preview") {
		if _pv.active {
			_pv_preview_off()
		} else {
			_pv.active = true
		}
	}
	if tinted do im.PopStyleColor()
	widgets.tooltip("Pose the object from this clip while the window is open")

	// Record: while armed, an edit of an animatable field keys the clip at the
	// playhead (record.odin). The record light is red whether armed or not,
	// brighter while armed. The Text push is what colors the glyph the shared
	// button draws. A read-only clip has nothing to record into.
	im.SameLine()
	if read_only do _pv.recording = false
	rec := _pv.recording
	im.PushStyleColorImVec4(.Text, rec ? im.Vec4{0.95, 0.25, 0.25, 1} : im.Vec4{0.75, 0.35, 0.35, 1})
	im.BeginDisabled(read_only)
	armed := widgets.icon_button(icons.ICON_MD_RECORD, "##rec",
		"Record: editing any animatable field keys it at the playhead, the object keeps its own value", active = rec)
	im.EndDisabled()
	im.PopStyleColor()
	if armed {
		_pv.recording = !_pv.recording
		if _pv.recording do _pv.active = true // recording poses the object, as previewing does
	}
	if !_pv.recording do _record_note_clear()

	// Transport: start, previous key, play, next key, end.
	im.SameLine()
	if widgets.icon_button(icons.ICON_MD_FIRST_PAGE, "##first", "Go to the start") {
		_pv.time = 0
		_pv.active = true
	}

	im.SameLine()
	if widgets.icon_button(icons.ICON_MD_PREV_KEY, "##prevkey", "Previous keyframe") {
		_pv.time = _pv_key_step(clip, _pv.time, back = true)
		_pv.active = true
	}

	im.SameLine()
	if widgets.icon_button(_pv.playing ? icons.ICON_MD_PAUSE : icons.ICON_MD_PLAY_ARROW, "##play", _pv.playing ? "Pause" : "Play the clip") {
		_pv.playing = !_pv.playing
		if _pv.playing {
			_pv.active = true
			// Pressing play with the playhead already at the end replays from
			// the start. Without this the first press only advances past the
			// end, which _pv_advance answers by rewinding AND stopping — so it
			// took two presses to play, the first one looking like a rewind.
			if _pv.time >= length do _pv.time = 0
		}
	}

	im.SameLine()
	if widgets.icon_button(icons.ICON_MD_NEXT_KEY, "##nextkey", "Next keyframe") {
		_pv.time = _pv_key_step(clip, _pv.time, back = false)
		_pv.active = true
	}

	im.SameLine()
	if widgets.icon_button(icons.ICON_MD_LAST_PAGE, "##last", "Go to the end") {
		_pv.time = length
		_pv.active = true
	}

	// Playback: once, loop, or as the clip's wrap setting. A click steps to the
	// next state, and the tooltip names the one a click gives.
	im.SameLine()
	glyph, tip: cstring
	switch _anim_playback() {
	case .Once:
		glyph, tip = icons.ICON_MD_REPEAT_ONE, "Play once, then stop\nClick: loop"
	case .Loop:
		glyph, tip = icons.ICON_MD_REPEAT, "Loop\nClick: match the clip's wrap setting"
	case .Clip:
		glyph = icons.ICON_MD_EVENT_REPEAT
		tip = fmt.ctprintf("Match the clip's wrap setting (%v)\nClick: play once", _pv_clip_wrap())
	}
	if widgets.icon_button(glyph, "##playback", tip) {
		anim_window_prefs.playback = Anim_Playback((int(anim_window_prefs.playback) + 1) % len(Anim_Playback))
	}

	// The playhead as a frame number, with the clip's frame count beside it.
	im.SameLine()
	im.SetNextItemWidth(58)
	frame := i32(math.round(_pv.time * fps))
	if im.InputInt("##pv_frame", &frame, 0, 0, {.EnterReturnsTrue}) {
		_pv.time = clamp(f32(frame) / fps, 0, length)
		_pv.active = true
	}
	widgets.tooltip("Playhead frame")
	im.SameLine()
	im.TextDisabled(fmt.ctprintf("/ %d", i32(math.round(length * fps))))

	if read_only {
		im.SameLine(0, 16)
		im.TextDisabled(icons.ICON_MD_LOCK + " Read-Only")
		widgets.tooltip("A clip inside a model is read-only. Assets/Extract Assets makes an editable .anim")
	}

	// No Save button: the tab menu saves and discards the clip, File/Save
	// saves it with every other file (session/documents.odin).
}

// The clip the window edits: the tab menu saves and discards it, and the tab
// title carries its star.
@(window_document={window="Animation"})
animation_window_document :: proc(window: session.Window_Ref) -> engine.Asset_GUID {
	doc, _ := _pv_doc()
	return doc.guid if doc != nil else {}
}

// Dopesheet / Curves, as tabs along the bottom of the sheet.
@(private = "file")
_pv_draw_mode_tabs :: proc() {
	if !im.BeginTabBar("##anim_modes", {}) do return
	defer im.EndTabBar()
	// imgui owns which tab is open and _av.mode follows it. Forcing the open
	// tab from _av.mode every frame would re-select the current one before a
	// click on the other could take effect.
	for mode in _Anim_Mode {
		if im.BeginTabItem(fmt.ctprintf("%v", mode), nil, {}) {
			_av.mode = mode
			im.EndTabItem()
		}
	}
}

// The nearest key time before or after `from` across every channel, so the
// transport steps between poses rather than by a fixed amount. Returns `from`
// when there is nothing further in that direction.
@(private = "file")
_pv_key_step :: proc(clip: ^anim.AnimationClip, from: f32, back: bool) -> f32 {
	if clip == nil do return from
	EPS :: f32(1e-5)
	best := from
	found := false
	for &ch in clip.channels {
		for t in ch.times {
			if back {
				if t < from - EPS && (!found || t > best) {
					best = t
					found = true
				}
			} else {
				if t > from + EPS && (!found || t < best) {
					best = t
					found = true
				}
			}
		}
	}
	return best
}

// This window's per-developer preferences, persisted to UserSettings/animation.json.
// Not project settings: where someone's playhead stops is about them, not the
// project, and the game binary has no business reading it.
Anim_Window_Prefs :: struct {
	// Where the playhead lands when a Once clip finishes: the last frame, or
	// back at the first. Off by default, which is how it has always behaved.
	ends_on_last_frame: bool,
	// The toolbar's playback toggle.
	playback: Anim_Playback,
	// The ruler over the time canvas (the window menu's three Ruler items).
	ruler: Anim_Ruler,
}

// How the transport plays a clip. Saved as an integer: Clip stays zero, so a
// settings file without the field follows the clip.
Anim_Playback :: enum {
	Clip, // as the clip's wrap setting says, which is what the component does
	Once, // plays through and stops, even a Loop clip
	Loop, // cycles, even a Once clip
}

// What the ruler over the time canvas shows. Saved as an integer: the
// default stays zero.
Anim_Ruler :: enum {
	Frames_And_Time, // two rulers, each half the band: time above, frames below
	Frames,
	Time,
}

@(private)
_anim_ruler :: proc() -> Anim_Ruler {
	r := anim_window_prefs.ruler
	if r < min(Anim_Ruler) || r > max(Anim_Ruler) do anim_window_prefs.ruler = .Frames_And_Time
	return anim_window_prefs.ruler
}

// The saved playback state. A settings file can hold an integer out of the
// enum's range, which reads as Clip and is stored back as Clip.
@(private = "file")
_anim_playback :: proc() -> Anim_Playback {
	p := anim_window_prefs.playback
	if p < min(Anim_Playback) || p > max(Anim_Playback) do anim_window_prefs.playback = .Clip
	return anim_window_prefs.playback
}

@(user_settings={name="Animation"})
anim_window_prefs: Anim_Window_Prefs

// The menu item is an ACTION with a checked predicate rather than a toggle,
// because a toggle writes through a ^bool and would need its own variable —
// two places holding the same preference, one of them persisted.
@(window_menu={window="Animation", label="Play Ends on Last Frame", checked=anim_ends_on_last_frame})
anim_toggle_ends_on_last_frame :: proc(window: session.Window_Ref) {
	anim_window_prefs.ends_on_last_frame = !anim_window_prefs.ends_on_last_frame
}

anim_ends_on_last_frame :: proc(window: session.Window_Ref) -> bool {
	return anim_window_prefs.ends_on_last_frame
}

// The ruler, a three-way choice in the Ruler submenu: one checked item per state.
@(window_menu={window="Animation", label="Ruler/Frames and Time", checked=anim_ruler_is_both})
anim_ruler_pick_both :: proc(window: session.Window_Ref) { anim_window_prefs.ruler = .Frames_And_Time }
@(window_menu={window="Animation", label="Ruler/Frames", checked=anim_ruler_is_frames})
anim_ruler_pick_frames :: proc(window: session.Window_Ref) { anim_window_prefs.ruler = .Frames }
@(window_menu={window="Animation", label="Ruler/Time", checked=anim_ruler_is_time})
anim_ruler_pick_time :: proc(window: session.Window_Ref) { anim_window_prefs.ruler = .Time }
anim_ruler_is_both :: proc(window: session.Window_Ref) -> bool { return _anim_ruler() == .Frames_And_Time }
anim_ruler_is_frames :: proc(window: session.Window_Ref) -> bool { return _anim_ruler() == .Frames }
anim_ruler_is_time :: proc(window: session.Window_Ref) -> bool { return _anim_ruler() == .Time }

// The IMPORTED clip's wrap, not the edited document's: wrap is authored in the
// .meta and baked into the artifact, so the document has none.
@(private = "file")
_pv_clip_wrap :: proc() -> anim.Animation_Wrap {
	if imported, ok := anim.animation_clip_load(_pv.clip); ok do return imported.wrap
	return .Once
}

// Advance the playhead while the transport runs. By default it wraps the way
// the clip itself does, so playback matches what the component will do — a
// Once clip plays through and stops, a Loop clip cycles. The playback toggle
// can force either.
@(private = "file")
_pv_advance :: proc(clip: ^anim.AnimationClip, length: f32) {
	if !_pv.playing do return
	gfx.keep_awake()
	_pv.time, _pv.playing = anim_playback_step(_pv.time, gfx.delta_time(), length,
		_pv_clip_wrap(), _anim_playback(), anim_window_prefs.ends_on_last_frame)
}

// One transport step of a running playhead: `time` advanced by `dt`, and
// past `length` wrapped by `playback`, which keeps `clip_wrap` (Clip) or
// forces Once or Loop. A Once playback stops there (playing false). No gfx
// or imgui calls.
anim_playback_step :: proc(time, dt, length: f32, clip_wrap: anim.Animation_Wrap, playback: Anim_Playback, ends_on_last_frame: bool) -> (new_time: f32, playing: bool) {
	new_time = time + dt
	if new_time < length do return new_time, true
	wrap := clip_wrap
	switch playback {
	case .Clip:
	case .Once: wrap = .Once
	case .Loop: wrap = .Loop
	}
	switch wrap {
	case .Loop:
		return new_time - length * math.floor(new_time / length), true
	case .Once:
		// Where a Once clip comes to rest. Ending ON the last frame is what you
		// want when the pose it lands in is the thing being authored — a death,
		// a landing, anything whose final frame is the point. Rewinding is what
		// you want when you are watching the motion over and over.
		return ends_on_last_frame ? length : 0, false
	}
	return new_time, true
}

// --- Test access -----------------------------------------------------------------------

// Test-only: selects key `key` of row `ch`, replacing the selection, or added
// to it when `add`, as a click and a modifier click on the key do.
animation_window_select_key :: proc(ch, key: int, add := false) {
	if add && !_pv_sel_has(ch, key) {
		_pv_sel_toggle(ch, key)
		return
	}
	_pv_sel_set(ch, key)
}

// Test-only: sets `mode` on every selected key of the shown clip, as the key
// context menu's Mode items and the footer's combo do.
animation_window_set_key_mode :: proc(mode: anim.Key_Mode) {
	doc, clip := _pv_doc()
	if doc == nil || clip == nil do return
	_pv_keys_set_mode(doc, clip, mode)
}

// Test-only: applies `preset` to every selected key of the shown clip, as the
// key context menu's tangent presets do.
animation_window_apply_preset :: proc(preset: Key_Preset) {
	doc, clip := _pv_doc()
	if doc == nil || clip == nil do return
	_pv_keys_apply_preset(doc, clip, preset)
}

// Test-only: clears the key selection.
animation_window_deselect :: proc() {
	_pv_deselect()
}

// Test-only: the row state of the window copy (with no window open, the
// spare copy): collapse an Object row, expand a vector row by its
// sheet_channel_key, ask either, and clear both.
animation_window_toggle_collapsed :: proc(target: string) { _pv_collapse_toggle(target) }
animation_window_is_collapsed :: proc(target: string) -> bool { return _av.collapsed[target] }
animation_window_toggle_expanded :: proc(key: string) { _pv_expand_toggle(key) }
animation_window_is_expanded :: proc(key: string) -> bool { return _av.expanded[key] }
animation_window_rows_clear :: proc() {
	context.allocator = runtime.default_allocator()
	for k in _av.collapsed do delete(k)
	clear(&_av.collapsed)
	for k in _av.expanded do delete(k)
	clear(&_av.expanded)
	_av.window_gen += 1
}

// Test-only: enables or disables lane `lane` of row `ch` in the shown clip, as
// the lane items of the property row's menu do.
animation_window_set_lane :: proc(ch, lane: int, on: bool) -> bool {
	doc, clip := _pv_doc()
	if doc == nil || clip == nil do return false
	return _pv_lane_set(doc, clip, ch, lane, on)
}

// Test-only: the animated object the window targets this frame, as
// _animation_frame asks.
animation_window_target :: proc() -> engine.Transform_Handle {
	owner, _ := _pv_target()
	return owner
}

// --- Commands and keymap -------------------------------------------------------
//
// The keymap resolver runs these before the windows draw (editor/keymap). The
// clip and its document are the preview's (_pv_doc), shared by every copy.
// The selection is _av's, which is the last clicked copy outside a draw.

@(command={name="Animation/Delete Key", enabled=animation_can_delete_key, help="Deletes the selected keys"})
animation_delete_key :: proc() {
	doc, clip := _pv_doc()
	if doc == nil || clip == nil do return
	_pv_sheet(doc, clip)
	_pv_delete_key(doc, clip)
}

// A key is selected in an editable clip. A clip inside a model has no
// document and is read-only.
animation_can_delete_key :: proc() -> bool {
	doc, clip := _pv_doc()
	if doc == nil || clip == nil do return keymap.disabled("No clip is open")
	return _pv_sel_valid(clip) || keymap.disabled("No key is selected")
}

@(keymap={name="Animation", window="Animation"})
animation_keymap :: proc(km: ^keymap.Keymap) {
	keymap.bind(km, "Delete", "Animation/Delete Key")
	keymap.bind(km, "Backspace", "Animation/Delete Key")
}
