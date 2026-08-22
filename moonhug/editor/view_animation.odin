package editor

// Animation window — Unity's Animation window on the PlayableGraph scrub path
// (docs/PlayableGraph.md steps 5+6): scrub preview plus dopesheet and curve
// editing for the clips on the selected object's Animation component.
//
// PREVIEW (step 5): never leaks into saved data. Each frame:
//   1. the window UI sets the scrub state (clip, time, on/off),
//   2. animation_preview_apply refreshes the binding defaults from the live
//      transforms, evaluates the clip at the scrub time and applies the pose,
//   3. the scene and game views render the posed world,
//   4. animation_preview_restore writes the defaults back.
// Outside that render window the world holds authored values, so saves, undo
// and the inspector are untouched by construction — there is no preview state
// to revert when preview ends, the target dies or its scene unloads.
//
// EDITING (step 6): keyframe operations edit the clip's ASSET DOCUMENT (the
// session registry the project inspector uses), so every operation is a
// whole-document undo step re-found by guid. Edits sync into the engine's
// clip cache (animation_clip_preview) the way material edits live-preview —
// that cache is what the scrub preview and any playing Animation component
// sample. Save writes the document to the .anim file; unsaved edits revert
// next editor run, same as materials.

import "core:encoding/uuid"
import "core:fmt"
import "core:math/linalg"
import "core:path/filepath"
import "core:strings"
import im "moonhug:external/odin-imgui"
import engine "../engine"
import anim "moonhug:packages/animation"
import ser "../engine/serialization"
import "inspector"
import "menu"
import "undo"

@(private = "file") _ANIM_LEFT_W :: f32(200) // property column
@(private = "file") _ANIM_RULER_H :: f32(22)
@(private = "file") _ANIM_ROW_H :: f32(20)
@(private = "file") _ANIM_PAD_X :: f32(10) // time gutter inside the canvas
@(private = "file") _ANIM_KEY_R :: f32(4)  // key diamond half-size
@(private = "file") _ANIM_HIT :: f32(6)    // key hit-test radius

// Curve colors per value component (x red, y green, z blue, w grey).
@(private = "file")
_ANIM_COMP_COLS :: [4]im.Vec4{
	{0.91, 0.35, 0.35, 1},
	{0.42, 0.85, 0.42, 1},
	{0.40, 0.58, 1.00, 1},
	{0.75, 0.75, 0.75, 1},
}

@(private = "file")
_Anim_Mode :: enum {
	Dopesheet,
	Curves,
}

@(private = "file")
_pv: struct {
	active:  bool, // preview on: the world renders the scrubbed pose
	applied: bool, // pose applied this frame, restore pending
	owner:   engine.Transform_Handle, // the Animation component's transform
	clip:    engine.Asset_GUID,
	time:    f32,
	graph:     anim.Playable_Graph, // the component's FULL authored graph
	binding:   anim.Animation_Binding,
	node:      anim.Playable_Handle, // the scrubbed clip's node (weight 1)
	graph_sig: u64, // authored clip set the graph was built from
	ready:     bool,

	mode:      _Anim_Mode,
	sel_ch:    int, // selected channel row, -1 = none
	sel_key:   int, // selected key in sel_ch, -1 = none
	drag_key:  bool, // canvas key drag in progress (undo snapshot open)
	drag_comp: int,  // curves: value component the drag edits, -1 = time only
	sync:      bool, // document edited this frame -> push to the clip cache
}

shutdown_animation_view :: proc() {
	_pv_teardown()
}

// Closing the window ends the preview (Unity behavior). Called from the main
// loop when the window toggle is off.
animation_preview_stop :: proc() {
	_pv.active = false
}

@(private = "file")
_pv_teardown :: proc() {
	if _pv.ready {
		anim.playable_graph_destroy(&_pv.graph)
		anim.animation_binding_destroy(&_pv.binding)
	}
	_pv.ready = false
	_pv.node = {}
}

@(private = "file")
_pv_deselect :: proc() {
	_pv.sel_ch = -1
	_pv.sel_key = -1
	_pv.drag_key = false
}

// The scrub preview's live graph, for the Playable Graph visualizer — nil
// unless the preview is on for `owner` and its graph exists.
@(private)
_pv_preview_graph :: proc(owner: engine.Transform_Handle) -> ^anim.Playable_Graph {
	if !_pv.active || !_pv.ready || _pv.owner != owner do return nil
	return &_pv.graph
}

// The Animation component the window targets: on the active selection or its
// nearest ancestor — Unity resolves the window's target the same way, so
// selecting a child bone keeps the window on the animated root. Shared with
// the Playable Graph visualizer, which targets identically.
@(private)
_pv_target :: proc() -> (owner: engine.Transform_Handle, a: ^anim.Animation) {
	w := engine.ctx_world()
	tH := sel_scene_active()
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

// Every clip reachable from the component: the default clip plus the authored
// layers' clips, deduplicated, temp-allocated.
@(private = "file")
_pv_clips :: proc(a: ^anim.Animation) -> []engine.Asset_GUID {
	clips := make([dynamic]engine.Asset_GUID, context.temp_allocator)
	_pv_clips_add(&clips, a.clip)
	for &l in a.layers {
		for c in l.clips do _pv_clips_add(&clips, c)
	}
	return clips[:]
}

@(private = "file")
_pv_clips_add :: proc(clips: ^[dynamic]engine.Asset_GUID, g: engine.Asset_GUID) {
	if g == {} do return
	for c in clips^ {
		if c == g do return
	}
	append(clips, g)
}

// Shared with the Playable Graph visualizer's clip node labels.
@(private)
_pv_clip_name :: proc(g: engine.Asset_GUID) -> string {
	if path, ok := engine.asset_db_get_path(uuid.Identifier(g)); ok {
		return filepath.stem(path)
	}
	return "(missing clip)"
}

// --- Document access and undo --------------------------------------------------------

// The selected clip's asset document — the edit target. Refetched every frame:
// undo/redo swaps the document payload, so pointers never survive a frame.
@(private = "file")
_pv_doc :: proc() -> (doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip) {
	if _pv.clip == {} do return nil, nil
	path, ok := engine.asset_db_get_path(uuid.Identifier(_pv.clip))
	if !ok do return nil, nil
	d := inspector.asset_doc_get(path)
	if d == nil || d.data.id != typeid_of(anim.AnimationClip) do return nil, nil
	return d, cast(^anim.AnimationClip)d.data.data
}

// The animation view edits a document across frames (dragging a keyframe), so
// its edit is a session like any other — opened when the gesture starts, closed
// when it ends. See docs/Undo.md.
@(private = "file")
_pv_session: undo.Edit_Session

// One whole-document undo step: the session captures the document before the
// mutation and records the result after. Drags open on press and close on
// release, mutating in between.
@(private = "file")
_pv_edit_begin :: proc(doc: ^inspector.Asset_Doc) {
	// Idempotent: the drag calls this on activation, and a second call while the
	// same gesture is open would otherwise capture the already-edited value.
	if undo.edit_session_active(&_pv_session) do return
	_pv_session = undo.edit_session_begin(
		{undo.edit_target_asset(doc.guid, doc.data.id)}, "Animation Edit")
}

@(private = "file")
_pv_edit_commit :: proc(doc: ^inspector.Asset_Doc) {
	undo.edit_session_end(&_pv_session)
	_pv_mark_edited(doc)
}

@(private = "file")
_pv_mark_edited :: proc(doc: ^inspector.Asset_Doc) {
	doc.dirty = true
	_pv.sync = true
}

// The inspector's field convention: the session opens when the widget
// activates and commits when it deactivates after an edit — one undo step per
// drag/typing session. Rotation keys renormalize at commit so slerp sampling
// stays valid without fighting the drag.
@(private = "file")
_pv_field_undo :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, changed: bool) {
	if im.IsItemActivated() do _pv_edit_begin(doc)
	if changed do _pv_mark_edited(doc)
	if im.IsItemDeactivatedAfterEdit() {
		if _pv_sel_valid(clip) {
			ch := &clip.channels[_pv.sel_ch]
			if ch.path == .Rotation do _pv_normalize_rot_key(ch, _pv.sel_key)
		}
		_pv_edit_commit(doc)
	}
}

@(private = "file")
_pv_normalize_rot_key :: proc(ch: ^anim.Animation_Channel, k: int) {
	v := ch.values[k]
	if l := linalg.length(v); l > 0.0001 do ch.values[k] = (1.0 / l) * v
}

@(private = "file")
_pv_sel_valid :: proc(clip: ^anim.AnimationClip) -> bool {
	if _pv.sel_ch < 0 || _pv.sel_ch >= len(clip.channels) do return false
	return _pv.sel_key >= 0 && _pv.sel_key < len(clip.channels[_pv.sel_ch].times)
}

// --- Keyframe operations --------------------------------------------------------------

// Insert a key at `t` sampling the curve's current value there, so adding a
// key never changes the curve's shape (Unity's Add Key).
@(private = "file")
_pv_add_key :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, ch_idx: int, t: f32) {
	if ch_idx < 0 || ch_idx >= len(clip.channels) do return
	ch := &clip.channels[ch_idx]
	t := clamp(t, 0, clip.length)
	for kt in ch.times {
		if abs(kt - t) < 0.0005 do return
	}
	v := anim._animation_channel_sample(ch, t)
	idx := len(ch.times)
	for kt, i in ch.times {
		if kt > t {
			idx = i
			break
		}
	}
	_pv_edit_begin(doc)
	inject_at(&ch.times, idx, t)
	inject_at(&ch.values, idx, v)
	_pv.sel_ch = ch_idx
	_pv.sel_key = idx
	_pv_edit_commit(doc)
}

// The last key of a channel stays — an empty channel samples to zero, which
// is never what a delete meant.
@(private = "file")
_pv_delete_key :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip) {
	if !_pv_sel_valid(clip) do return
	ch := &clip.channels[_pv.sel_ch]
	if len(ch.times) <= 1 do return
	_pv_edit_begin(doc)
	ordered_remove(&ch.times, _pv.sel_key)
	ordered_remove(&ch.values, _pv.sel_key)
	_pv.sel_key = -1
	_pv_edit_commit(doc)
}

// A dragged key stays between its neighbors (and inside the clip), so the
// times array keeps its sort order without reindexing mid-drag.
@(private = "file")
_pv_drag_time_bounds :: proc(ch: ^anim.Animation_Channel, k: int, length: f32) -> (lo, hi: f32) {
	lo = k > 0 ? ch.times[k - 1] : 0
	hi = k < len(ch.times) - 1 ? ch.times[k + 1] : length
	return
}

// --- Window ---------------------------------------------------------------------------

draw_animation_view :: proc() {
	if !im.Begin("Animation", &menu.show_animation, {.NoCollapse}) {
		// Tabbed-away, not closed: the preview keeps running.
		im.End()
		return
	}
	defer im.End()

	owner, a := _pv_target()
	if a == nil {
		_pv.active = false
		im.TextDisabled("Select an object with an Animation component.")
		return
	}
	// Retarget follows selection (Unity): the old target's graph and binding
	// belong to the old owner.
	if owner != _pv.owner {
		_pv_teardown()
		_pv_deselect()
		_pv.owner = owner
	}

	clips := _pv_clips(a)
	if len(clips) == 0 {
		_pv.active = false
		im.TextDisabled("The Animation component has no clips.")
		return
	}
	in_list := false
	for c in clips {
		if c == _pv.clip do in_list = true
	}
	if !in_list {
		_pv_teardown()
		_pv_deselect()
		_pv.clip = clips[0]
		_pv.time = 0
	}

	doc, clip := _pv_doc()
	length := clip != nil ? max(clip.length, 0.0001) : 0.0001

	_pv_draw_toolbar(doc, clip, clips, length)

	if clip == nil {
		im.TextDisabled("The clip has no document (missing or unreadable .anim).")
		return
	}
	// Undo may have shrunk the clip since the selection was made.
	if _pv.sel_ch >= len(clip.channels) do _pv_deselect()
	if _pv.sel_ch >= 0 && _pv.sel_key >= len(clip.channels[_pv.sel_ch].times) do _pv.sel_key = -1

	footer := _pv_sel_valid(clip)
	im.BeginChild("##anim_body", im.Vec2{0, footer ? -(im.GetFrameHeight() + 8) : 0}, {.Borders})
	_pv_draw_sheet(doc, clip)
	im.EndChild()

	// Delete on the selected key; text input (a drag field being typed into)
	// owns Backspace.
	if _pv_sel_valid(clip) && !im.GetIO().WantTextInput &&
	   im.IsWindowFocused({.ChildWindows}) &&
	   (im.IsKeyPressed(.Delete) || im.IsKeyPressed(.Backspace)) {
		_pv_delete_key(doc, clip)
	}

	if footer && _pv_sel_valid(clip) {
		_pv_draw_key_footer(doc, clip)
	}

	// Push this frame's edits into the engine cache the preview samples from.
	if _pv.sync {
		_pv.sync = false
		if d2, c2 := _pv_doc(); c2 != nil {
			anim.animation_clip_preview(d2.guid, c2^)
		}
	}
}

@(private = "file")
_pv_draw_toolbar :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, clips: []engine.Asset_GUID, length: f32) {
	// Preview toggle (Unity's Animation window preview button). The pop must
	// match the state at push time — the click flips _pv.active in between.
	tinted := _pv.active
	if tinted do im.PushStyleColorImVec4(.Button, im.GetStyleColorVec4(.ButtonActive)^)
	if im.Button("Preview") do _pv.active = !_pv.active
	if tinted do im.PopStyleColor()

	im.SameLine()
	im.SetNextItemWidth(180)
	cur := strings.clone_to_cstring(_pv_clip_name(_pv.clip), context.temp_allocator)
	if im.BeginCombo("##pv_clip", cur) {
		for c in clips {
			name := strings.clone_to_cstring(_pv_clip_name(c), context.temp_allocator)
			if im.Selectable(name, c == _pv.clip) && c != _pv.clip {
				_pv_teardown()
				_pv_deselect()
				_pv.clip = c
				_pv.time = 0
			}
		}
		im.EndCombo()
	}

	im.SameLine()
	im.SetNextItemWidth(70)
	if im.DragFloat("##pv_time", &_pv.time, 0.005, 0, length, "%.3f") {
		_pv.active = true // scrubbing enters preview, like Unity
	}
	_pv.time = clamp(_pv.time, 0, length)
	im.SameLine()
	im.TextUnformatted(fmt.ctprintf("/ %.3f s", length))

	im.SameLine()
	for mode in _Anim_Mode {
		m_tinted := _pv.mode == mode
		if m_tinted do im.PushStyleColorImVec4(.Button, im.GetStyleColorVec4(.ButtonActive)^)
		if im.Button(fmt.ctprintf("%v", mode)) do _pv.mode = mode
		if m_tinted do im.PopStyleColor()
		im.SameLine()
	}

	if clip != nil && doc != nil {
		im.BeginDisabled(_pv.sel_ch < 0 || _pv.sel_ch >= len(clip.channels))
		if im.Button("Add Key") do _pv_add_key(doc, clip, _pv.sel_ch, _pv.time)
		im.EndDisabled()

		im.SameLine()
		im.BeginDisabled(!doc.dirty)
		if im.Button(doc.dirty ? "Save *" : "Save") {
			if ser.save_to_file(doc.path, doc.data) do doc.dirty = false
		}
		im.EndDisabled()
	} else {
		// Terminate the mode buttons' trailing SameLine.
		im.NewLine()
	}
}

// The sheet: property rows on the left, the time canvas (ruler + dopesheet
// keys or curves) on the right, one interaction surface each.
@(private = "file")
_pv_draw_sheet :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip) {
	dl := im.GetWindowDrawList()
	origin := im.GetCursorScreenPos()
	avail := im.GetContentRegionAvail()
	if avail.x < _ANIM_LEFT_W + 80 {
		im.TextDisabled("Window too narrow.")
		return
	}

	length := max(clip.length, 0.0001)
	x0 := origin.x + _ANIM_LEFT_W
	x1 := origin.x + avail.x
	pps := (x1 - x0 - 2 * _ANIM_PAD_X) / length // pixels per second
	tx0 := x0 + _ANIM_PAD_X                     // x of t=0

	nrows := len(clip.channels)
	rows_y := origin.y + _ANIM_RULER_H
	body_h: f32
	if _pv.mode == .Dopesheet {
		body_h = max(f32(nrows) * _ANIM_ROW_H, _ANIM_ROW_H)
	} else {
		body_h = max(f32(nrows)*_ANIM_ROW_H, max(avail.y - _ANIM_RULER_H, 140))
	}

	// --- Ruler: dragging it scrubs (the only scrub surface, like Unity).
	im.SetCursorScreenPos(im.Vec2{x0, origin.y})
	im.InvisibleButton("##anim_ruler", im.Vec2{max(x1 - x0, 1), _ANIM_RULER_H})
	if im.IsItemActive() {
		_pv.time = clamp((im.GetMousePos().x - tx0) / pps, 0, clip.length)
		_pv.active = true
	}
	im.DrawList_AddRectFilled(dl, im.Vec2{x0, origin.y}, im.Vec2{x1, origin.y + _ANIM_RULER_H}, im.GetColorU32(.FrameBg, 0.6))
	steps := [?]f32{0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 30, 60}
	step := steps[len(steps) - 1]
	for s in steps {
		if s * pps >= 55 {
			step = s
			break
		}
	}
	tick_col := im.GetColorU32(.TextDisabled)
	for i in 0 ..= int(length / step) {
		t := f32(i) * step
		tx := tx0 + t * pps
		im.DrawList_AddLine(dl, im.Vec2{tx, origin.y + _ANIM_RULER_H - 6}, im.Vec2{tx, origin.y + _ANIM_RULER_H}, tick_col, 1)
		im.DrawList_AddText(dl, im.Vec2{tx + 3, origin.y + 3}, tick_col, fmt.ctprintf("%.2f", t))
	}

	// --- Rows surface (left panel + canvas share it; hit-tested by x).
	im.SetCursorScreenPos(im.Vec2{origin.x, rows_y})
	im.InvisibleButton("##anim_sheet", im.Vec2{avail.x, body_h})
	hovered := im.IsItemHovered()
	mp := im.GetMousePos()
	row_at := hovered ? int((mp.y - rows_y) / _ANIM_ROW_H) : -1

	// Left panel rows (both modes: this is where curves pick their channel).
	im.DrawList_PushClipRect(dl, im.Vec2{origin.x, rows_y}, im.Vec2{x0 - 2, rows_y + body_h}, true)
	for &ch, i in clip.channels {
		ry := rows_y + f32(i) * _ANIM_ROW_H
		if i == _pv.sel_ch {
			im.DrawList_AddRectFilled(dl, im.Vec2{origin.x, ry}, im.Vec2{x0, ry + _ANIM_ROW_H}, im.GetColorU32(.Header, 0.7))
		} else if i % 2 == 1 {
			im.DrawList_AddRectFilled(dl, im.Vec2{origin.x, ry}, im.Vec2{x0, ry + _ANIM_ROW_H}, im.GetColorU32(.FrameBg, 0.25))
		}
		target := ch.target == "" ? "(self)" : ch.target
		im.DrawList_AddText(dl, im.Vec2{origin.x + 6, ry + 3}, im.GetColorU32(.Text), fmt.ctprintf("%s : %v", target, ch.path))
	}
	im.DrawList_PopClipRect(dl)
	im.DrawList_AddLine(dl, im.Vec2{x0, origin.y}, im.Vec2{x0, rows_y + body_h}, im.GetColorU32(.Border), 1)

	if _pv.mode == .Dopesheet {
		_pv_sheet_dopesheet(doc, clip, dl, origin, rows_y, body_h, x0, x1, tx0, pps, hovered, mp, row_at)
	} else {
		_pv_sheet_curves(doc, clip, dl, rows_y, body_h, x0, x1, tx0, pps, mp, row_at)
	}

	// Playhead over everything.
	px := tx0 + clamp(_pv.time, 0, length) * pps
	head_col := im.GetColorU32ImVec4(im.Vec4{0.92, 0.28, 0.28, 1})
	im.DrawList_AddLine(dl, im.Vec2{px, origin.y}, im.Vec2{px, rows_y + body_h}, head_col, 1)
	im.DrawList_AddTriangleFilled(dl, im.Vec2{px - 5, origin.y}, im.Vec2{px + 5, origin.y}, im.Vec2{px, origin.y + 8}, head_col)

	// Shared drag update/commit (a drag started in either mode).
	if _pv.drag_key {
		if !_pv_sel_valid(clip) {
			// The key vanished mid-drag, so there is no edit to record.
			_pv.drag_key = false
			undo.edit_session_abort(&_pv_session)
		} else if im.IsMouseDown(.Left) {
			ch := &clip.channels[_pv.sel_ch]
			lo, hi := _pv_drag_time_bounds(ch, _pv.sel_key, clip.length)
			ch.times[_pv.sel_key] = clamp((mp.x - tx0) / pps, lo, hi)
			if _pv.drag_comp >= 0 {
				// Curves: y edits the grabbed component's value.
				ch.values[_pv.sel_key][_pv.drag_comp] = _pv_curve_y_to_v(mp.y, rows_y, body_h)
			}
			_pv_mark_edited(doc)
		} else {
			ch := &clip.channels[_pv.sel_ch]
			if ch.path == .Rotation && _pv.drag_comp >= 0 do _pv_normalize_rot_key(ch, _pv.sel_key)
			_pv_edit_commit(doc)
			_pv.drag_key = false
		}
	}

	// Key context menu (opened by the mode-specific right-click handling).
	if im.BeginPopup("##anim_key_ctx") {
		can_delete := _pv_sel_valid(clip) && len(clip.channels[_pv.sel_ch].times) > 1
		if im.MenuItem("Delete Key", nil, false, can_delete) do _pv_delete_key(doc, clip)
		im.EndPopup()
	}
}

// --- Dopesheet ------------------------------------------------------------------------

@(private = "file")
_pv_key_hit_x :: proc(ch: ^anim.Animation_Channel, mx, tx0, pps: f32) -> int {
	best := -1
	best_d := _ANIM_HIT
	for t, k in ch.times {
		d := abs(tx0 + t * pps - mx)
		if d < best_d {
			best_d = d
			best = k
		}
	}
	return best
}

@(private = "file")
_pv_sheet_dopesheet :: proc(
	doc: ^inspector.Asset_Doc,
	clip: ^anim.AnimationClip,
	dl: ^im.DrawList,
	origin: im.Vec2,
	rows_y, body_h, x0, x1, tx0, pps: f32,
	hovered: bool,
	mp: im.Vec2,
	row_at: int,
) {
	// Row stripes + keys.
	for &ch, i in clip.channels {
		ry := rows_y + f32(i) * _ANIM_ROW_H
		if i % 2 == 1 {
			im.DrawList_AddRectFilled(dl, im.Vec2{x0, ry}, im.Vec2{x1, ry + _ANIM_ROW_H}, im.GetColorU32(.FrameBg, 0.25))
		}
		ky := ry + _ANIM_ROW_H * 0.5
		for t, k in ch.times {
			kx := tx0 + t * pps
			sel := i == _pv.sel_ch && k == _pv.sel_key
			col := sel ? im.GetColorU32(.CheckMark) : im.GetColorU32(.Text)
			r := sel ? _ANIM_KEY_R + 1 : _ANIM_KEY_R
			im.DrawList_AddQuadFilled(dl,
				im.Vec2{kx, ky - r}, im.Vec2{kx + r, ky},
				im.Vec2{kx, ky + r}, im.Vec2{kx - r, ky}, col)
		}
	}

	valid_row := row_at >= 0 && row_at < len(clip.channels)

	if im.IsItemActivated() && valid_row {
		_pv.sel_ch = row_at
		_pv.sel_key = -1
		if mp.x >= x0 {
			if k := _pv_key_hit_x(&clip.channels[row_at], mp.x, tx0, pps); k >= 0 {
				_pv.sel_key = k
				_pv_edit_begin(doc)
				_pv.drag_key = true
				_pv.drag_comp = -1
			}
		}
	}
	if im.IsItemClicked(.Right) && valid_row {
		_pv.sel_ch = row_at
		if k := _pv_key_hit_x(&clip.channels[row_at], mp.x, tx0, pps); k >= 0 && mp.x >= x0 {
			_pv.sel_key = k
			im.OpenPopup("##anim_key_ctx")
		}
	}
	// Double-click on empty canvas: add a key there (sampled, shape-preserving).
	if hovered && valid_row && mp.x >= x0 && im.IsMouseDoubleClicked(.Left) {
		if _pv_key_hit_x(&clip.channels[row_at], mp.x, tx0, pps) < 0 {
			_pv_add_key(doc, clip, row_at, (mp.x - tx0) / pps)
		}
	}
}

// --- Curves ---------------------------------------------------------------------------

// Value range of the curve area this frame (set during draw, read by the drag
// update). Range follows the selected channel's keys with 10% padding.
@(private = "file")
_curve_vmin, _curve_vmax: f32

@(private = "file")
_pv_curve_v_to_y :: proc(v, rows_y, body_h: f32) -> f32 {
	span := max(_curve_vmax - _curve_vmin, 0.0001)
	return rows_y + 6 + (1 - (v - _curve_vmin) / span) * (body_h - 12)
}

@(private = "file")
_pv_curve_y_to_v :: proc(y, rows_y, body_h: f32) -> f32 {
	span := max(_curve_vmax - _curve_vmin, 0.0001)
	return _curve_vmin + (1 - (y - rows_y - 6) / max(body_h - 12, 1)) * span
}

@(private = "file")
_pv_sheet_curves :: proc(
	doc: ^inspector.Asset_Doc,
	clip: ^anim.AnimationClip,
	dl: ^im.DrawList,
	rows_y, body_h, x0, x1, tx0, pps: f32,
	mp: im.Vec2,
	row_at: int,
) {
	// Left-panel click selects the channel whose curves show.
	if im.IsItemActivated() && mp.x < x0 && row_at >= 0 && row_at < len(clip.channels) {
		_pv.sel_ch = row_at
		_pv.sel_key = -1
	}

	if _pv.sel_ch < 0 || _pv.sel_ch >= len(clip.channels) {
		im.DrawList_AddText(dl, im.Vec2{x0 + 12, rows_y + 8}, im.GetColorU32(.TextDisabled), "Select a property to edit its curves.")
		return
	}
	ch := &clip.channels[_pv.sel_ch]
	ncomp := ch.path == .Rotation ? 4 : 3

	// Freeze the value range while dragging — a range that follows the edited
	// value makes the curve chase the cursor.
	if !_pv.drag_key {
		vmin, vmax := max(f32), min(f32)
		for v in ch.values {
			for c in 0 ..< ncomp {
				vmin = min(vmin, v[c])
				vmax = max(vmax, v[c])
			}
		}
		if vmax < vmin {
			vmin, vmax = 0, 1
		}
		if vmax - vmin < 0.001 {
			vmin -= 0.5
			vmax += 0.5
		}
		pad := (vmax - vmin) * 0.1
		_curve_vmin, _curve_vmax = vmin - pad, vmax + pad
	}

	// Value grid: min, max and zero when visible.
	grid_col := im.GetColorU32(.Border, 0.6)
	for v in ([3]f32{_curve_vmin, _curve_vmax, 0}) {
		if v < _curve_vmin || v > _curve_vmax do continue
		gy := _pv_curve_v_to_y(v, rows_y, body_h)
		im.DrawList_AddLine(dl, im.Vec2{x0, gy}, im.Vec2{x1, gy}, grid_col, 1)
		im.DrawList_AddText(dl, im.Vec2{x0 + 4, gy - 14}, im.GetColorU32(.TextDisabled), fmt.ctprintf("%.3g", v))
	}

	// One polyline per component, sampled (slerp and step are not linear
	// between keys), keys as squares on top.
	im.DrawList_PushClipRect(dl, im.Vec2{x0, rows_y}, im.Vec2{x1, rows_y + body_h}, true)
	comp_cols := _ANIM_COMP_COLS
	for c in 0 ..< ncomp {
		col := im.GetColorU32ImVec4(comp_cols[c])
		pts := make([dynamic]im.Vec2, context.temp_allocator)
		for x := tx0; x <= x1 - _ANIM_PAD_X + 3; x += 3 {
			v := anim._animation_channel_sample(ch, (x - tx0) / pps)
			append(&pts, im.Vec2{x, _pv_curve_v_to_y(v[c], rows_y, body_h)})
		}
		if len(pts) >= 2 {
			im.DrawList_AddPolyline(dl, raw_data(pts[:]), i32(len(pts)), col, 1.5)
		}
		for t, k in ch.times {
			kx := tx0 + t * pps
			ky := _pv_curve_v_to_y(ch.values[k][c], rows_y, body_h)
			sel := k == _pv.sel_key && c == _pv.drag_comp
			r := sel ? f32(4) : f32(3)
			im.DrawList_AddRectFilled(dl, im.Vec2{kx - r, ky - r}, im.Vec2{kx + r, ky + r}, sel ? im.GetColorU32(.CheckMark) : col)
		}
	}
	im.DrawList_PopClipRect(dl)

	// Press on a key square: drag edits (time, value[comp]).
	if im.IsItemActivated() && mp.x >= x0 {
		best_k, best_c := -1, -1
		best_d := _ANIM_HIT
		for t, k in ch.times {
			kx := tx0 + t * pps
			for c in 0 ..< ncomp {
				ky := _pv_curve_v_to_y(ch.values[k][c], rows_y, body_h)
				d := max(abs(kx - mp.x), abs(ky - mp.y))
				if d < best_d {
					best_d = d
					best_k, best_c = k, c
				}
			}
		}
		_pv.sel_key = best_k
		if best_k >= 0 {
			_pv.drag_comp = best_c
			_pv_edit_begin(doc)
			_pv.drag_key = true
		}
	}
	if im.IsItemClicked(.Right) && mp.x >= x0 {
		if k := _pv_key_hit_x(ch, mp.x, tx0, pps); k >= 0 {
			_pv.sel_key = k
			im.OpenPopup("##anim_key_ctx")
		}
	}
}

// --- Selected-key footer ----------------------------------------------------------------

@(private = "file")
_pv_draw_key_footer :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip) {
	ch := &clip.channels[_pv.sel_ch]
	k := _pv.sel_key

	im.AlignTextToFramePadding()
	im.TextUnformatted(fmt.ctprintf("Key %d   t", k))
	im.SameLine()
	im.SetNextItemWidth(70)
	lo, hi := _pv_drag_time_bounds(ch, k, clip.length)
	_pv_field_undo(doc, clip, im.DragFloat("##anim_key_t", &ch.times[k], 0.002, lo, hi, "%.3f"))

	ncomp := ch.path == .Rotation ? 4 : 3
	comp_names := [4]cstring{"x", "y", "z", "w"}
	for c in 0 ..< ncomp {
		im.SameLine()
		im.TextUnformatted(comp_names[c])
		im.SameLine()
		im.SetNextItemWidth(70)
		_pv_field_undo(doc, clip, im.DragFloat(fmt.ctprintf("##anim_key_v%d", c), &ch.values[k][c], 0.01))
	}

	im.SameLine()
	im.BeginDisabled(len(ch.times) <= 1)
	if im.Button("Delete Key") do _pv_delete_key(doc, clip)
	im.EndDisabled()
}

// --- Preview apply/restore (main loop hooks) --------------------------------------------

// A fingerprint of the component's authored clip set, so the preview graph
// rebuilds when layers/clips are edited while previewing.
@(private = "file")
_pv_authored_sig :: proc(a: ^anim.Animation) -> u64 {
	sig := u64(0xcbf29ce484222325)
	_pv_sig_mix(&sig, a.clip)
	for &l in a.layers {
		sig ~= 0x9e37
		for c in l.clips do _pv_sig_mix(&sig, c)
	}
	return sig
}

@(private = "file")
_pv_sig_mix :: proc(sig: ^u64, g: engine.Asset_GUID) {
	bytes := transmute([16]u8)g
	for b in bytes do sig^ = (sig^ ~ u64(b)) * 0x100000001b3
}

// The scrub preview evaluates the component's FULL authored graph — layer
// mixer root, one mixer per authored layer, every clip a leaf — with the
// scrubbed clip at weight 1 and everything else at 0. The zero-weight nodes
// cost nothing (the evaluator skips them) and change nothing in the pose,
// but the preview path is the graph the component actually plays, and the
// Playable Graph visualizer shows the real topology with live weights.
@(private = "file")
_pv_build_graph :: proc(a: ^anim.Animation) {
	anim.playable_graph_init(&_pv.graph)
	anim.animation_binding_init(&_pv.binding, _pv.owner)
	_pv.graph.root = anim.playable_add(&_pv.graph, anim.Layer_Mixer_Playable{})
	_pv.node = {}

	n_layers := max(len(a.layers), 1)
	for li in 0 ..< n_layers {
		mixer := anim.playable_add(&_pv.graph, anim.Mixer_Playable{})
		anim.playable_connect(&_pv.graph, _pv.graph.root, mixer, 1)

		clips := make([dynamic]engine.Asset_GUID, context.temp_allocator)
		if li == 0 do _pv_clips_add(&clips, a.clip)
		if li < len(a.layers) {
			for c in a.layers[li].clips do _pv_clips_add(&clips, c)
		}
		for c in clips {
			node := anim.playable_add(&_pv.graph, anim.Clip_Playable{clip = c})
			w := f32(0)
			if c == _pv.clip && _pv.node == {} {
				_pv.node = node
				w = 1
			}
			anim.playable_connect(&_pv.graph, mixer, node, w)
		}
	}
	_pv.graph_sig = _pv_authored_sig(a)
	_pv.ready = true
}

// Apply the preview pose for this frame's scene/game render. Runs in the main
// loop after the window UI set the scrub state, right before the world renders.
animation_preview_apply :: proc() {
	if !_pv.active do return
	w := engine.ctx_world()
	if !engine.pool_valid(&w.transforms, engine.Handle(_pv.owner)) || _pv.clip == {} {
		_pv.active = false
		return
	}
	_, a := engine.transform_get_comp(_pv.owner, anim.Animation)
	if a == nil {
		_pv.active = false
		return
	}
	clip, ok := anim.animation_clip_load(_pv.clip)
	if !ok do return

	if _pv.ready && _pv.graph_sig != _pv_authored_sig(a) do _pv_teardown()
	if !_pv.ready do _pv_build_graph(a)
	if n := anim.playable_node(&_pv.graph, _pv.node); n != nil {
		n.time = clamp(_pv.time, 0, clip.length)
	}

	anim.animation_binding_refresh_defaults(&_pv.binding)
	pose := anim.playable_graph_evaluate(&_pv.graph, &_pv.binding)
	anim.animation_pose_apply(&_pv.binding, pose)
	_pv.applied = true
}

// Restore the authored pose after the scene/game render. The world spends the
// rest of the frame — saves, undo, inspector — at authored values.
animation_preview_restore :: proc() {
	if !_pv.applied do return
	_pv.applied = false
	anim.animation_binding_write_defaults(&_pv.binding)
}
