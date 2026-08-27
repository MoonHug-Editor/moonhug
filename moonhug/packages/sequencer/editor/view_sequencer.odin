package sequencer_editor

// Sequencer window (docs/Sequencer.md) — Unity's Timeline window on the
// director scrub path, laid out after ImGuizmo's ImSequencer: a legend
// column (mute, track name, binding, add-clip) beside a scrollable canvas
// (seconds ruler + playhead + clip blocks with move/resize grips), a
// selected-clip strip below.
//
// TARGETS the selection like the Animation window: the active transform or
// its nearest ancestor with a PlayableDirector, read through the
// UserContext inspector channel (the editor root publishes it per frame). Edits go to the timeline's
// ASSET DOCUMENT (inspector.asset_doc_get) with whole-document undo
// sessions, then sync into the runtime cache (timeline_preview) so playing
// directors and the preview pick them up; Save writes the file.
//
// PREVIEW: the playhead poses the world only for the scene/game render —
// sequencer_preview_apply/restore bracket the render in main.odin exactly
// like the animation scrub preview. Activation flips are captured and
// restored per frame; particle systems reset when the preview ends.

import "core:encoding/uuid"
import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:strings"
import im "moonhug:external/odin-imgui"
import engine "moonhug:engine"
import ser "moonhug:engine/serialization"
import seq "moonhug:packages/sequencer"
import "moonhug:editor/inspector"
import "moonhug:editor/undo"
import wnd "moonhug:editor/window"
import "moonhug:editor/preview"

_SQ_ROW_H :: f32(26)
_SQ_RULER_H :: f32(22)
_SQ_SPLIT_W :: f32(4) // splitter thickness / hit area
_SQ_MIN_PANE :: f32(120)

// A draggable splitter: `size` is the pane BEFORE it, clamped so both sides
// keep _SQ_MIN_PANE. Returns after drawing; the caller lays out around it.
@(private = "file")
_sq_splitter :: proc(id: cstring, vertical: bool, size: ^f32, total: f32) {
	thickness := _SQ_SPLIT_W
	im.InvisibleButton(id, vertical ? im.Vec2{thickness, im.GetContentRegionAvail().y} : im.Vec2{-1, thickness})
	if im.IsItemHovered({}) || im.IsItemActive() {
		im.SetMouseCursor(vertical ? .ResizeEW : .ResizeNS)
		p0 := im.GetItemRectMin()
		p1 := im.GetItemRectMax()
		im.DrawList_AddRectFilled(im.GetWindowDrawList(), p0, p1, im.GetColorU32(.SeparatorHovered))
	}
	if im.IsItemActive() {
		delta := vertical ? im.GetIO().MouseDelta.x : im.GetIO().MouseDelta.y
		size^ = clamp(size^ + delta, _SQ_MIN_PANE, max(total - _SQ_MIN_PANE, _SQ_MIN_PANE))
	}
}

@(private = "file")
_sq: struct {
	preview:   bool, // the playhead poses the world for the render
	playing:   bool, // auto-advance the playhead
	time:      f32,
	pps:       f32, // pixels per second (zoom)
	sel_track: int,
	sel_clip:  int,
	drag:      enum {
		None,
		Move,
		Resize_L,
		Resize_R,
	},
	drag_off:  f32,
	// pane sizes, dragged by the splitters (imgui.ini does not persist
	// child sizes, so these live here for the session)
	legend_w:    f32,
	inspector_w: f32,
	// preview identity + per-frame restore state
	dir_owner:   engine.Transform_Handle,
	applied:     bool,
	act_targets: [dynamic]engine.Handle,
	act_values:  [dynamic]bool,
}

@(private = "file")
_sq_session: undo.Edit_Session

// Rename buffers: the clip strip's name field reloads when the selection
// changes, the track popup's when it opens.
@(private = "file") _sq_clip_name_buf: [128]u8
@(private = "file") _sq_clip_name_for: [2]int = {-1, -1}
@(private = "file") _sq_track_name_buf: [128]u8
// Where the row's context menu was opened — the menu itself draws under the
// moved mouse, so "Add Clip Here" must remember the click.
@(private = "file") _sq_ctx_time: f32

@(private = "file")
_sq_buf_set :: proc(buf: []u8, text: string) {
	n := min(len(text), len(buf) - 1)
	copy(buf[:n], text[:n])
	buf[n] = 0
}

@(private = "file")
_sq_buf_get :: proc(buf: []u8) -> string {
	return string(cstring(raw_data(buf)))
}

// The PlayableDirector the window targets: the active selection or its
// nearest ancestor (the Animation window's rule).
@(private = "file")
_sq_target :: proc() -> (owner: engine.Transform_Handle, d: ^seq.PlayableDirector) {
	w := engine.ctx_world()
	tH := engine.inspector_active_selection()
	for engine.pool_valid(&w.transforms, engine.Handle(tH)) {
		if _, comp := engine.transform_get_comp(tH, seq.PlayableDirector); comp != nil {
			return tH, comp
		}
		t := engine.pool_get(&w.transforms, engine.Handle(tH))
		if t == nil do break
		tH = engine.Transform_Handle(t.parent.handle)
	}
	return {}, nil
}

@(private = "file")
_sq_doc :: proc(d: ^seq.PlayableDirector) -> (doc: ^inspector.Asset_Doc, tl: ^seq.Timeline) {
	if engine.asset_guid_is_empty(d.timeline.guid) do return nil, nil
	path, ok := engine.asset_db_get_path(uuid.Identifier(d.timeline.guid))
	if !ok do return nil, nil
	dc := inspector.asset_doc_get(path)
	if dc == nil || dc.data.id != typeid_of(seq.Timeline) do return nil, nil
	return dc, cast(^seq.Timeline)dc.data.data
}

// Whole-document undo session, opened on a gesture's start and committed on
// its end (the Animation window's convention).
@(private = "file")
_sq_edit_begin :: proc(doc: ^inspector.Asset_Doc) {
	if undo.edit_session_active(&_sq_session) do return
	_sq_session = undo.edit_session_begin(
		{undo.edit_target_asset(doc.guid, doc.data.id)}, "Timeline Edit")
}

@(private = "file")
_sq_edit_commit :: proc(doc: ^inspector.Asset_Doc, d: ^seq.PlayableDirector, tl: ^seq.Timeline) {
	undo.edit_session_end(&_sq_session)
	_sq_mark_edited(doc, d, tl)
}

// Dirty + sync into the runtime cache so directors and the preview play the
// edited values (the file keeps the last saved state until Save).
@(private = "file")
_sq_mark_edited :: proc(doc: ^inspector.Asset_Doc, d: ^seq.PlayableDirector, tl: ^seq.Timeline) {
	doc.dirty = true
	seq.timeline_preview(engine.Asset_GUID(d.timeline.guid), tl^)
}

// Drag-widget undo: session on activation, commit on release.
@(private = "file")
_sq_field_undo :: proc(doc: ^inspector.Asset_Doc, d: ^seq.PlayableDirector, tl: ^seq.Timeline, changed: bool) {
	if im.IsItemActivated() do _sq_edit_begin(doc)
	if changed do _sq_mark_edited(doc, d, tl)
	if im.IsItemDeactivated() do _sq_edit_commit(doc, d, tl)
}

// Adds a clip at `at` seconds and selects it — the + button, the row's
// context menu and double-click all land here.
@(private = "file")
_sq_add_clip :: proc(doc: ^inspector.Asset_Doc, d: ^seq.PlayableDirector, tl: ^seq.Timeline, ti: int, at: f32) {
	track := &tl.tracks[ti]
	_sq_edit_begin(doc)
	append(&track.clips, seq.Timeline_Clip{
		start    = max(math.round(at * 10) / 10, 0),
		duration = track.kind == "marker" ? 0 : 1,
		name     = strings.clone(track.kind == "marker" ? "marker" : "clip"),
	})
	_sq_edit_commit(doc, d, tl)
	_sq.sel_track = ti
	_sq.sel_clip = len(track.clips) - 1
}

@(private = "file")
_sq_delete_clip :: proc(doc: ^inspector.Asset_Doc, d: ^seq.PlayableDirector, tl: ^seq.Timeline, ti, ci: int) {
	track := &tl.tracks[ti]
	_sq_edit_begin(doc)
	delete(track.clips[ci].name)
	ordered_remove(&track.clips, ci)
	_sq_edit_commit(doc, d, tl)
	_sq.sel_clip = -1
}

@(private = "file")
_sq_duplicate_clip :: proc(doc: ^inspector.Asset_Doc, d: ^seq.PlayableDirector, tl: ^seq.Timeline, ti, ci: int) {
	track := &tl.tracks[ti]
	_sq_edit_begin(doc)
	dup := track.clips[ci]
	dup.name = strings.clone(track.clips[ci].name)
	dup.start += max(dup.duration, 0.1)
	append(&track.clips, dup)
	_sq_edit_commit(doc, d, tl)
	_sq.sel_track = ti
	_sq.sel_clip = len(track.clips) - 1
}

@(private = "file")
_sq_binding_type :: proc(kind: string) -> string {
	if desc, ok := seq.track_desc(kind); ok do return desc.binding_type
	return ""
}

@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
sequencer_preview_install :: proc() {
	preview.register({apply = sequencer_preview_apply, restore = sequencer_preview_restore})
}

@(menu_item={path="Window/Sequencer", shortcut=""})
sequencer_menu_open :: proc() {
	wnd.open("sequencer")
}

@(editor_window={id="sequencer", title="Sequencer", width=1100, height=420})
sequencer_window_draw :: proc() {
	if _sq.pps == 0 do _sq.pps = 120
	if _sq.legend_w == 0 do _sq.legend_w = 230
	if _sq.inspector_w == 0 do _sq.inspector_w = 260
	owner, d := _sq_target()
	if d == nil {
		_sq.preview = false
		im.TextDisabled("Select an object with a PlayableDirector component.")
		return
	}
	if owner != _sq.dir_owner {
		// New target: the preview restarts cleanly.
		_sq.dir_owner = owner
		_sq.playing = false
		_sq.time = 0
		_sq.sel_track = -1
	}

	// --- Timeline assignment row -------------------------------------------------
	doc, tl := _sq_doc(d)
	if tl == nil {
		im.TextUnformatted("Timeline:")
		im.SameLine()
		if im.SmallButton("Assign...") do im.OpenPopup("sq_assign")
		if im.BeginPopup("sq_assign") {
			for path in engine.asset_db.path_to_guid {
				if !strings.has_suffix(path, ".timeline") do continue
				if im.Selectable(fmt.ctprintf("%s", path)) {
					if raw_guid, gok := engine.asset_db_get_guid(path); gok {
						comp_owned, _ := engine.transform_get_comp_key(owner, .PlayableDirector)
						sess := undo.edit_session_begin(
							{undo.edit_target_pooled(comp_owned.handle, &d.timeline, typeid_of(engine.PPtr))},
							"Assign Timeline")
						d.timeline = {guid = engine.Asset_GUID(raw_guid)}
						undo.edit_session_end(&sess)
					}
				}
			}
			im.EndPopup()
		}
		im.TextDisabled("No timeline assigned (create one via Assets/Create/Timeline).")
		_sq.preview = false
		return
	}

	// --- Toolbar -------------------------------------------------------------------
	dur := max(seq.timeline_duration(tl), 0.001)
	if im.Checkbox("Preview", &_sq.preview) {
		if !_sq.preview do _sq.playing = false
	}
	im.SameLine()
	if im.SmallButton("|<") {
		_sq.time = 0
		_sq.preview = true
	}
	im.SameLine()
	if im.SmallButton(_sq.playing ? "Pause" : "Play") {
		_sq.playing = !_sq.playing
		if _sq.playing do _sq.preview = true
	}
	im.SameLine()
	im.Text("%6.2fs / %.2fs", _sq.time, dur)
	im.SameLine()
	im.SetNextItemWidth(90)
	dur_changed := im.DragFloat("##sq_dur", &tl.duration, 0.05, 0, 0, "len %.2f")
	im.SetItemTooltip("Timeline duration (0 = last clip end)")
	_sq_field_undo(doc, d, tl, dur_changed)
	im.SameLine()
	im.BeginDisabled(!doc.dirty)
	if im.Button(doc.dirty ? "Save *" : "Save") {
		if ser.save_to_file(doc.path, doc.data) do doc.dirty = false
	}
	im.EndDisabled()
	im.SameLine()
	if im.SmallButton("Add Track") do im.OpenPopup("sq_add_track")
	if im.BeginPopup("sq_add_track") {
		for kind in seq.track_kinds() {
			if im.Selectable(fmt.ctprintf("%s", kind)) do _sq_add_track(doc, d, tl, kind)
		}
		im.EndPopup()
	}

	// --- Legend | canvas | inspector, splitters between --------------------------
	body_h := im.GetContentRegionAvail().y
	total_w := im.GetContentRegionAvail().x
	rows_h := _SQ_RULER_H + f32(len(tl.tracks)) * _SQ_ROW_H
	_sq.legend_w = clamp(_sq.legend_w, _SQ_MIN_PANE, max(total_w - 2 * _SQ_MIN_PANE, _SQ_MIN_PANE))
	_sq.inspector_w = clamp(_sq.inspector_w, _SQ_MIN_PANE, max(total_w - _sq.legend_w - _SQ_MIN_PANE, _SQ_MIN_PANE))

	if im.BeginChild("##sq_legend", im.Vec2{_sq.legend_w, body_h}) {
		im.Dummy(im.Vec2{1, _SQ_RULER_H - 4}) // align with the ruler
		remove_track := -1
		for &track, ti in tl.tracks {
			im.PushIDInt(i32(ti))
			muted := track.muted
			if im.Checkbox("##mute", &muted) {
				_sq_edit_begin(doc)
				track.muted = muted
				_sq_edit_commit(doc, d, tl)
			}
			im.SetItemTooltip("Mute")
			im.SameLine()
			label := len(track.name) > 0 ? track.name : track.kind
			im.TextUnformatted(fmt.ctprintf("%s", label))
			im.SetItemTooltip("%s track — right-click for options", track.kind)
			im.OpenPopupOnItemClick("track_ctx")
			if im.BeginPopup("track_ctx") {
				if im.Selectable("Add Clip at Playhead") do _sq_add_clip(doc, d, tl, ti, _sq.time)
				if im.Selectable("Rename...", false, {.NoAutoClosePopups}) {
					_sq_buf_set(_sq_track_name_buf[:], track.name)
					im.OpenPopup("track_rename")
				}
				if im.BeginPopup("track_rename") {
					im.SetKeyboardFocusHere()
					enter := im.InputText("##track_name", cstring(raw_data(_sq_track_name_buf[:])),
						len(_sq_track_name_buf), {.EnterReturnsTrue})
					if enter {
						_sq_edit_begin(doc)
						delete(track.name)
						track.name = strings.clone(_sq_buf_get(_sq_track_name_buf[:]))
						_sq_edit_commit(doc, d, tl)
						im.CloseCurrentPopup()
					}
					im.EndPopup()
				}
				if im.Selectable("Remove Track") do remove_track = ti
				im.EndPopup()
			}
			im.SameLine()
			// Binding: which scene object this track drives. Lives on the
			// DIRECTOR; the session diffs and records only real changes.
			bt := _sq_binding_type(track.kind)
			if bt == "" {
				im.TextDisabled(track.kind == "animation" ? "(owner)" : "-")
			} else {
				comp_owned, _ := engine.transform_get_comp_key(owner, .PlayableDirector)
				sess := undo.edit_session_begin(
					{undo.edit_target_whole(comp_owned.handle)}, "Track Binding")
				// The ref picker mints the target's local_id against the
				// OWNER's root scene, which it reads from the inspector owner
				// stack — without this push the scene is nil, no id is minted,
				// and the binding holds only a runtime handle that dies with
				// the next scene reload (Play/Stop lost the binding).
				undo.push_component_owner(comp_owned.handle)
				defer undo.pop_owner()
				b := _sq_binding_slot(d, i32(ti))
				before := b.target.local_id
				inspector.current_field_ref_target = bt
				im.SetNextItemWidth(-46)
				if drawer := inspector.resolve_property_drawer(typeid_of(engine.Ref_Local)); drawer != nil {
					drawer(&b.target, typeid_of(engine.Ref_Local), "##bind")
				}
				inspector.current_field_ref_target = ""
				changed := b.target.local_id != before
				undo.edit_session_end(&sess)
				if changed do inspector.mark_inspector_changed()
				im.SameLine()
			}
			if im.SmallButton("+") do _sq_add_clip(doc, d, tl, ti, _sq.time)
			im.SetItemTooltip("Add clip at the playhead")
			im.SameLine()
			if im.SmallButton("x") do remove_track = ti
			im.SetItemTooltip("Remove track")
			// Pad the row to the canvas row height.
			im.Dummy(im.Vec2{1, _SQ_ROW_H - im.GetFrameHeightWithSpacing()})
			im.PopID()
		}
		if remove_track >= 0 {
			_sq_edit_begin(doc)
			track := &tl.tracks[remove_track]
			for &c in track.clips do delete(c.name)
			delete(track.clips)
			delete(track.kind)
			delete(track.name)
			ordered_remove(&tl.tracks, remove_track)
			_sq_edit_commit(doc, d, tl)
			_sq.sel_track = -1
		}
	}
	im.EndChild()
	im.SameLine(0, 0)
	_sq_splitter("##sq_split_l", true, &_sq.legend_w, total_w - _sq.inspector_w)
	im.SameLine(0, 0)

	canvas_pane_w := max(total_w - _sq.legend_w - _sq.inspector_w - 2 * _SQ_SPLIT_W, _SQ_MIN_PANE)
	if im.BeginChild("##sq_canvas", im.Vec2{canvas_pane_w, body_h}, {}, {.HorizontalScrollbar}) {
		dl := im.GetWindowDrawList()
		origin := im.GetCursorScreenPos()
		canvas_w := max(dur * _sq.pps + 120, im.GetContentRegionAvail().x)
		im.Dummy(im.Vec2{canvas_w, rows_h}) // reserves the scrollable extent

		// Zoom on wheel (the canvas is hovered; scrollbar still pans).
		if im.IsWindowHovered({}) {
			if wheel := im.GetIO().MouseWheel; wheel != 0 {
				_sq.pps = clamp(_sq.pps * math.pow(f32(1.15), wheel), 20, 2000)
			}
		}

		to_x :: proc(origin: im.Vec2, t: f32) -> f32 { return origin.x + t * _sq.pps }
		from_x :: proc(origin: im.Vec2, x: f32) -> f32 { return (x - origin.x) / _sq.pps }

		// Ruler: second ticks + labels; dragging scrubs.
		ruler_max := im.Vec2{origin.x + canvas_w, origin.y + _SQ_RULER_H}
		im.DrawList_AddRectFilled(dl, origin, ruler_max, im.GetColorU32(.FrameBg))
		step := _sq.pps < 60 ? f32(5) : _sq.pps < 200 ? f32(1) : f32(0.5)
		for t := f32(0); t <= dur + 0.0001; t += step {
			x := to_x(origin, t)
			im.DrawList_AddLine(dl, {x, origin.y + 10}, {x, origin.y + _SQ_RULER_H}, im.GetColorU32(.Border))
			im.DrawList_AddText(dl, {x + 3, origin.y}, im.GetColorU32(.TextDisabled), fmt.ctprintf("%g", t))
		}
		im.SetCursorScreenPos(origin)
		im.InvisibleButton("##sq_ruler", im.Vec2{canvas_w, _SQ_RULER_H})
		if im.IsItemActive() {
			_sq.time = clamp(from_x(origin, im.GetMousePos().x), 0, dur)
			_sq.preview = true
			_sq.playing = false
		}

		// Track rows + clips. Structural clip actions from the context menu
		// defer to after the loops — mutating clips mid-iteration would
		// invalidate the range.
		act_dup := [2]int{-1, -1}
		act_del := [2]int{-1, -1}
		for &track, ti in tl.tracks {
			row_y := origin.y + _SQ_RULER_H + f32(ti) * _SQ_ROW_H
			im.DrawList_AddLine(dl, {origin.x, row_y + _SQ_ROW_H}, {origin.x + canvas_w, row_y + _SQ_ROW_H}, im.GetColorU32(.Border))

			// Row background: click deselects, double-click creates a clip
			// there, right-click offers the same from a menu. AllowOverlap is
			// load-bearing — without it this full-width button swallows every
			// click meant for the clip blocks submitted after it.
			im.SetCursorScreenPos(im.Vec2{origin.x, row_y})
			im.PushIDInt(i32(1000 + ti))
			im.SetNextItemAllowOverlap()
			im.InvisibleButton("##row", im.Vec2{canvas_w, _SQ_ROW_H})
			row_t := from_x(origin, im.GetMousePos().x)
			if im.IsItemHovered({}) && im.IsMouseDoubleClicked(.Left) {
				_sq_add_clip(doc, d, tl, ti, row_t)
			} else if im.IsItemActivated() {
				_sq.sel_track = ti
				_sq.sel_clip = -1
			}
			if im.IsItemHovered({}) && im.IsMouseReleased(.Right) do _sq_ctx_time = row_t
			im.OpenPopupOnItemClick("row_ctx")
			if im.BeginPopup("row_ctx") {
				if im.Selectable("Add Clip Here") do _sq_add_clip(doc, d, tl, ti, _sq_ctx_time)
				im.EndPopup()
			}
			im.PopID()

			for &c, ci in track.clips {
				x0 := to_x(origin, c.start)
				x1 := to_x(origin, c.start + max(c.duration, 0.05))
				r0 := im.Vec2{x0, row_y + 3}
				r1 := im.Vec2{x1, row_y + _SQ_ROW_H - 3}
				selected := _sq.sel_track == ti && _sq.sel_clip == ci
				col := _sq_track_color(track.kind)
				if track.muted do col.w *= 0.35
				im.DrawList_AddRectFilled(dl, r0, r1, im.GetColorU32ImVec4(col), 3)
				if selected {
					// Binding order is (rounding, thickness, flags) — unlike native imgui.
					im.DrawList_AddRect(dl, r0, r1, im.GetColorU32ImVec4({1, 0.85, 0.2, 1}), 3, 2)
				}
				// Ease ramps read as corner triangles, Unity-style.
				if c.ease_in > 0 {
					ex := to_x(origin, c.start + min(c.ease_in, c.duration))
					im.DrawList_AddLine(dl, {x0, r1.y}, {ex, r0.y}, im.GetColorU32ImVec4({1, 1, 1, 0.5}))
				}
				if c.ease_out > 0 {
					ex := to_x(origin, c.start + c.duration - min(c.ease_out, c.duration))
					im.DrawList_AddLine(dl, {ex, r0.y}, {x1, r1.y}, im.GetColorU32ImVec4({1, 1, 1, 0.5}))
				}
				label := len(c.name) > 0 ? c.name : _sq_asset_label(c.asset)
				im.DrawList_PushClipRect(dl, r0, r1, true)
				im.DrawList_AddText(dl, {r0.x + 4, r0.y + 2}, im.GetColorU32(.Text), fmt.ctprintf("%s", label))
				im.DrawList_PopClipRect(dl)

				// Interaction: edges resize, body moves.
				im.SetCursorScreenPos(r0)
				im.PushIDInt(i32(ti * 1024 + ci))
				im.InvisibleButton("##clip", im.Vec2{max(r1.x - r0.x, 8), r1.y - r0.y})
				hovered := im.IsItemHovered({})
				mx := im.GetMousePos().x
				near_l := hovered && mx < r0.x + 6 && c.duration > 0
				near_r := hovered && mx > r1.x - 6 && c.duration > 0
				if near_l || near_r do im.SetMouseCursor(.ResizeEW)
				if im.IsItemHovered({}) && im.IsMouseReleased(.Right) {
					_sq.sel_track = ti
					_sq.sel_clip = ci
				}
				im.OpenPopupOnItemClick("clip_ctx")
				if im.BeginPopup("clip_ctx") {
					if im.Selectable("Duplicate") do act_dup = {ti, ci}
					if im.Selectable("Delete") do act_del = {ti, ci}
					im.EndPopup()
				}
				if im.IsItemActivated() {
					_sq.sel_track = ti
					_sq.sel_clip = ci
					_sq.drag = near_l ? .Resize_L : near_r ? .Resize_R : .Move
					_sq.drag_off = from_x(origin, mx) - c.start
					_sq_edit_begin(doc)
				}
				if im.IsItemActive() && _sq.sel_track == ti && _sq.sel_clip == ci {
					t_mouse := from_x(origin, mx)
					snap :: proc(v: f32) -> f32 { return math.round(v * 10) / 10 }
					switch _sq.drag {
					case .Move:
						end := c.start + c.duration
						c.start = clamp(snap(t_mouse - _sq.drag_off), 0, dur - c.duration)
						_ = end
						_sq_mark_edited(doc, d, tl)
					case .Resize_L:
						end := c.start + c.duration
						c.start = clamp(snap(t_mouse), 0, end - 0.1)
						c.duration = end - c.start
						_sq_mark_edited(doc, d, tl)
					case .Resize_R:
						c.duration = max(snap(t_mouse) - c.start, 0.1)
						_sq_mark_edited(doc, d, tl)
					case .None:
					}
				}
				if im.IsItemDeactivated() {
					_sq.drag = .None
					_sq_edit_commit(doc, d, tl)
				}
				im.PopID()
			}
		}

		if act_dup[0] >= 0 do _sq_duplicate_clip(doc, d, tl, act_dup[0], act_dup[1])
		if act_del[0] >= 0 do _sq_delete_clip(doc, d, tl, act_del[0], act_del[1])

		// Playhead over everything.
		px := to_x(origin, _sq.time)
		im.DrawList_AddLine(dl, {px, origin.y}, {px, origin.y + rows_h}, im.GetColorU32ImVec4({1, 0.3, 0.25, 1}), 2)
	}
	im.EndChild()

	// Keyboard: Delete/Backspace removes the selected clip — unless a text
	// field owns the keyboard.
	if im.IsWindowFocused(im.FocusedFlags_RootAndChildWindows) && !im.GetIO().WantTextInput {
		if (im.IsKeyPressed(.Delete) || im.IsKeyPressed(.Backspace)) &&
		   _sq.sel_track >= 0 && _sq.sel_track < len(tl.tracks) {
			if _sq.sel_clip >= 0 && _sq.sel_clip < len(tl.tracks[_sq.sel_track].clips) {
				_sq_delete_clip(doc, d, tl, _sq.sel_track, _sq.sel_clip)
			}
		}
	}

	// --- Inspector pane: the selected clip's fields, one per row -----------------
	im.SameLine(0, 0)
	_sq_splitter("##sq_split_r", true, &_sq.inspector_w, total_w - _sq.legend_w)
	im.SameLine(0, 0)
	if im.BeginChild("##sq_inspector", im.Vec2{0, body_h}, {.Borders}) {
		_sq_inspector_pane(doc, d, tl)
	}
	im.EndChild()
}

// The selected clip's properties, stacked vertically like the object
// inspector — the sequencer's own inspector pane.
@(private = "file")
_sq_inspector_pane :: proc(doc: ^inspector.Asset_Doc, d: ^seq.PlayableDirector, tl: ^seq.Timeline) {
	if _sq.sel_track < 0 || _sq.sel_track >= len(tl.tracks) {
		im.TextDisabled("No selection.")
		im.TextWrapped("Click a track row or clip. Double-click empty row space to add a clip.")
		return
	}
	track := &tl.tracks[_sq.sel_track]
	{
		im.SeparatorText("Track")
		im.Text("%s", fmt.ctprintf("%s (%s)", len(track.name) > 0 ? track.name : track.kind, track.kind))
		muted := track.muted
		if im.Checkbox("Muted", &muted) {
			_sq_edit_begin(doc)
			track.muted = muted
			_sq_edit_commit(doc, d, tl)
		}
		im.Text("%d clips", i32(len(track.clips)))
	}
	if _sq.sel_clip < 0 || _sq.sel_clip >= len(track.clips) {
		im.SeparatorText("Clip")
		im.TextDisabled("No clip selected.")
		return
	}
	{
		c := &track.clips[_sq.sel_clip]
		im.SeparatorText("Clip")

		// The clip's name — what the marker hook fires with, and the block's
		// label. The buffer reloads when the selection changes, the document
		// takes the value on commit (one undo step).
		if _sq_clip_name_for != {_sq.sel_track, _sq.sel_clip} {
			_sq_clip_name_for = {_sq.sel_track, _sq.sel_clip}
			_sq_buf_set(_sq_clip_name_buf[:], c.name)
		}
		im.SetNextItemWidth(-1)
		im.InputTextWithHint("##c_name", "Name", cstring(raw_data(_sq_clip_name_buf[:])), len(_sq_clip_name_buf))
		if im.IsItemDeactivatedAfterEdit() {
			_sq_edit_begin(doc)
			delete(c.name)
			c.name = strings.clone(_sq_buf_get(_sq_clip_name_buf[:]))
			_sq_edit_commit(doc, d, tl)
		}

		row :: proc(label: cstring) {
			im.TextUnformatted(label)
			im.SameLine(90)
			im.SetNextItemWidth(-1)
		}
		row("Start")
		_sq_field_undo(doc, d, tl, im.DragFloat("##c_start", &c.start, 0.02, 0, 0, "%.2f s"))
		row("Duration")
		_sq_field_undo(doc, d, tl, im.DragFloat("##c_dur", &c.duration, 0.02, 0, 0, "%.2f s"))
		row("Ease In")
		_sq_field_undo(doc, d, tl, im.DragFloat("##c_ein", &c.ease_in, 0.01, 0, 0, "%.2f s"))
		row("Ease Out")
		_sq_field_undo(doc, d, tl, im.DragFloat("##c_eout", &c.ease_out, 0.01, 0, 0, "%.2f s"))
		row("Speed")
		_sq_field_undo(doc, d, tl, im.DragFloat("##c_speed", &c.speed, 0.01, 0, 0, "x%.2f"))
		im.SetItemTooltip("0 behaves as 1")

		// The clip's payload asset, filtered per track kind.
		ext := track.kind == "animation" ? "anim" : track.kind == "audio" ? "mp3,wav,ogg" : ""
		if ext != "" {
			row("Asset")
			sess := undo.edit_session_begin({undo.edit_target_asset(doc.guid, doc.data.id)}, "Clip Asset")
			before := c.asset
			inspector.current_field_ext_filter = ext
			if drawer := inspector.resolve_property_drawer(typeid_of(engine.Asset_GUID)); drawer != nil {
				drawer(&c.asset, typeid_of(engine.Asset_GUID), "##c_asset")
			}
			inspector.current_field_ext_filter = ""
			changed := c.asset != before
			undo.edit_session_end(&sess)
			if changed do _sq_mark_edited(doc, d, tl)
		}

		im.Spacing()
		if im.Button("Duplicate", {-1, 0}) do _sq_duplicate_clip(doc, d, tl, _sq.sel_track, _sq.sel_clip)
		if im.Button("Delete", {-1, 0}) do _sq_delete_clip(doc, d, tl, _sq.sel_track, _sq.sel_clip)
	}
}

@(private = "file")
_sq_binding_slot :: proc(d: ^seq.PlayableDirector, track: i32) -> ^seq.Track_Binding {
	for &b in d.bindings {
		if b.track == track do return &b
	}
	append(&d.bindings, seq.Track_Binding{track = track})
	return &d.bindings[len(d.bindings) - 1]
}

@(private = "file")
_sq_add_track :: proc(doc: ^inspector.Asset_Doc, d: ^seq.PlayableDirector, tl: ^seq.Timeline, kind: string) {
	_sq_edit_begin(doc)
	track := seq.Timeline_Track{kind = strings.clone(kind), name = strings.clone(kind)}
	track.clips = make([dynamic]seq.Timeline_Clip)
	append(&tl.tracks, track)
	_sq_edit_commit(doc, d, tl)
}

@(private = "file")
_sq_track_color :: proc(kind: string) -> im.Vec4 {
	switch kind {
	case "animation":  return {0.30, 0.50, 0.80, 0.9}
	case "audio":      return {0.75, 0.55, 0.25, 0.9}
	case "activation": return {0.40, 0.70, 0.40, 0.9}
	case "particles":  return {0.65, 0.40, 0.75, 0.9}
	case "marker":     return {0.80, 0.35, 0.35, 0.9}
	}
	return {0.5, 0.5, 0.5, 0.9}
}

@(private = "file")
_sq_asset_label :: proc(g: engine.Asset_GUID) -> string {
	if engine.asset_guid_is_empty(g) do return "(empty)"
	if path, ok := engine.asset_db_get_path(uuid.Identifier(g)); ok {
		return filepath.stem(path)
	}
	return "(missing)"
}

// --- Preview apply/restore (main loop hooks) --------------------------------------------

// Pose the world at the playhead for the scene/game render only — bracketed
// with sequencer_preview_restore around the render in main.odin, like the
// animation scrub preview. Registry tracks run with scrub semantics
// (particles replay deterministically, audio stays silent); activation flips
// are captured here and restored after the render.
sequencer_preview_apply :: proc() {
	if !_sq.preview do return
	w := engine.ctx_world()
	if !engine.pool_valid(&w.transforms, engine.Handle(_sq.dir_owner)) {
		_sq_preview_end()
		return
	}
	_, d := engine.transform_get_comp(_sq.dir_owner, seq.PlayableDirector)
	if d == nil {
		_sq_preview_end()
		return
	}
	tl, ok := seq.timeline_load(engine.Asset_GUID(d.timeline.guid))
	if !ok do return

	if _sq.playing {
		dur := max(seq.timeline_duration(tl), 0.001)
		_sq.time += im.GetIO().DeltaTime
		if _sq.time >= dur do _sq.time = 0
	}

	// Capture what the tracks will mutate, restore after the render.
	clear(&_sq.act_targets)
	clear(&_sq.act_values)
	for &track, ti in tl.tracks {
		if track.kind != "activation" do continue
		b := _sq_binding_of(d, i32(ti))
		if !engine.pool_valid(&w.transforms, b.handle) do continue
		if t := engine.pool_get(&w.transforms, b.handle); t != nil {
			append(&_sq.act_targets, b.handle)
			append(&_sq.act_values, t.is_active)
		}
	}
	seq.director_set_time(d, _sq.time)
	_sq.applied = true
}

sequencer_preview_restore :: proc() {
	if !_sq.applied do return
	_sq.applied = false
	w := engine.ctx_world()
	_, d := engine.transform_get_comp(_sq.dir_owner, seq.PlayableDirector)
	// Track kinds restore whatever they drove (poses, activation, audio,
	// particles) — the window knows no kind by name.
	if d != nil do seq.director_preview_end(d)
	for h, i in _sq.act_targets {
		if !engine.pool_valid(&w.transforms, h) do continue
		if t := engine.pool_get(&w.transforms, h); t != nil {
			t.is_active = _sq.act_values[i]
		}
	}
}

// The preview stops being valid (target gone, window retargeted): let every
// track quiet what it was driving.
@(private = "file")
_sq_preview_end :: proc() {
	_sq.preview = false
	_sq.playing = false
	w := engine.ctx_world()
	if !engine.pool_valid(&w.transforms, engine.Handle(_sq.dir_owner)) do return
	_, d := engine.transform_get_comp(_sq.dir_owner, seq.PlayableDirector)
	if d != nil do seq.director_preview_end(d)
}

@(private = "file")
_sq_binding_of :: proc(d: ^seq.PlayableDirector, track: i32) -> engine.Ref_Local {
	for &b in d.bindings {
		if b.track == track do return b.target
	}
	return {}
}
