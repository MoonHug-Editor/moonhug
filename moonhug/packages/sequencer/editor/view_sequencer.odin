package sequencer_editor

// Sequencer window (docs/Sequencer.md) — Unity's Timeline window on the
// director scrub path, laid out after ImGuizmo's ImSequencer: a legend
// column (mute, track name, target, add-clip) beside a scrollable canvas
// (seconds ruler + playhead + clip blocks with move/resize grips), an
// inspector pane for the selection.
//
// TARGETS the selection like the Animation window: the active transform or
// its nearest ancestor with a PlayableDirector, read through the UserContext
// inspector channel (the editor root publishes it per frame).
//
// The timeline IS the director's subtree (timeline-as-prefab), so every edit
// here is an ordinary scene edit: field edits are component undo sessions,
// structural edits are node create/delete/duplicate through the same undo
// the hierarchy uses, and the director picks changes up live (its structural
// fingerprint rebuilds track state). Save saves the owner's scene.
//
// PREVIEW: the playhead poses the world only for the scene/game render —
// sequencer_preview_apply/restore bracket the render in main.odin exactly
// like the animation scrub preview.

import "core:fmt"
import "core:math"
import "core:strings"
import im "moonhug:external/odin-imgui"
import engine "moonhug:engine"
import seq "moonhug:packages/sequencer"
import "moonhug:editor/inspector"
import "moonhug:editor/undo"
import wnd "moonhug:editor/window"
import "moonhug:editor/preview"

// Material icon codepoints, declared locally like the inspector package does
// — editor/material_icons.odin lives in the editor ROOT, which packages do
// not import.
@(private = "file") _ICON_VOLUME_UP :: "\ue050"  // volume_up
@(private = "file") _ICON_VOLUME_OFF :: "\ue04f" // volume_off

_SQ_TAIL_S :: f32(2) // canvas room past the timeline end, seconds
_SQ_ROW_H :: f32(26)
_SQ_RULER_H :: f32(22)
_SQ_SPLIT_W :: f32(4) // splitter thickness / hit area
_SQ_MIN_PANE :: f32(120)

// A draggable splitter. `size` is the pane it resizes, clamped so both sides
// keep _SQ_MIN_PANE. `after` says that pane lies AFTER the splitter, so
// dragging toward it must GROW it — without the flip the right pane resizes
// backwards. Returns after drawing; the caller lays out around it.
@(private = "file")
_sq_splitter :: proc(id: cstring, vertical: bool, size: ^f32, total: f32, after := false) {
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
		if after do delta = -delta
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
}

@(private = "file")
_sq_session: undo.Edit_Session

// Rename buffers: the clip pane's name field reloads when the selection
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

// Whole-component undo session for a drag gesture: begin on activation,
// mutate the live component in between, end on release (diffs, records only
// real changes).
@(private = "file")
_sq_session_begin :: proc(comp: engine.Handle, label: string) {
	if undo.edit_session_active(&_sq_session) do return
	_sq_session = undo.edit_session_begin({undo.edit_target_whole(comp)}, label)
}

@(private = "file")
_sq_session_end :: proc() {
	undo.edit_session_end(&_sq_session)
}

// Drag-widget undo on one component: session on activation, commit on release.
@(private = "file")
_sq_field_undo :: proc(comp: engine.Handle, label: string, changed: bool) {
	if im.IsItemActivated() do _sq_session_begin(comp, label)
	if changed do inspector.mark_inspector_changed()
	if im.IsItemDeactivated() do _sq_session_end()
}

// The track/clip components behind a view row.
@(private = "file")
_sq_track_comp :: proc(tv: ^seq.Track_View) -> (engine.Handle, ^seq.TimelineTrack) {
	owned, tc := seq.get_comp(tv.node, seq.TimelineTrack)
	return owned.handle, tc
}

@(private = "file")
_sq_clip_comp :: proc(c: ^seq.Clip_View) -> (engine.Handle, ^seq.TimelineClip) {
	owned, cc := seq.get_comp(c.node, seq.TimelineClip)
	return owned.handle, cc
}

// Adds a clip NODE at `at` seconds and selects it — the + button, the row's
// context menu and double-click all land here.
@(private = "file")
_sq_add_clip :: proc(tv: ^seq.Track_View, ti: int, at: f32) {
	desc, has := seq.track_desc(tv.kind)
	node := engine.transform_new("clip", tv.node)
	_, cc := engine.transform_get_or_add_comp(node, seq.TimelineClip)
	if cc != nil {
		cc.start = max(math.round(at * 10) / 10, 0)
		cc.duration = 1
	}
	// The kind's clip component carries its payload (the .anim, the wav, ...).
	if has && desc.clip_key != engine.INVALID_TYPE_KEY {
		engine.transform_add_comp(node, desc.clip_key)
	}
	undo.record_create(node, tv.node)
	_sq.sel_track = ti
	_sq.sel_clip = -2 // re-resolved next frame; -2 keeps "something selected"
}

@(private = "file")
_sq_delete_clip :: proc(c: ^seq.Clip_View) {
	undo.record_delete(c.node)
	_sq.sel_clip = -1
}

@(private = "file")
_sq_duplicate_clip :: proc(tv: ^seq.Track_View, c: ^seq.Clip_View) {
	g := undo.group_begin("Duplicate Clip")
	defer undo.group_end(&g)
	dup := engine.scene_duplicate_subtree(c.node)
	if dup == {} do return
	undo.record_create(dup, tv.node)
	if _, cc := seq.get_comp(dup, seq.TimelineClip); cc != nil {
		cc.start += max(cc.duration, 0.1)
	}
	undo.group_commit(&g)
}

@(private = "file")
_sq_add_track :: proc(owner: engine.Transform_Handle, desc: seq.Track_Desc) {
	node := engine.transform_new(desc.label, owner)
	engine.transform_get_or_add_comp(node, seq.TimelineTrack)
	// The kind component is the discriminator — the registry finds the hooks
	// through its TypeKey.
	engine.transform_add_comp(node, desc.track_key)
	undo.record_create(node, owner)
}

// Component-owned strings never borrow the temp allocator.
@(private = "file")
_sq_clone :: proc(s: string) -> string {
	buf := make([]u8, len(s))
	copy(buf, s)
	return string(buf)
}

// A kind label for UI, from the registry.
@(private = "file")
_sq_kind_label :: proc(kind: engine.TypeKey) -> string {
	if desc, ok := seq.track_desc(kind); ok do return desc.label
	return "?"
}

// Draw a node's kind component EXACTLY the way the Inspector window draws a
// component (view_hierarchy_inspector's header-open block): the field rows'
// own gesture transactions record undo — one record per drag or typing
// gesture, opened on widget activation and closed on release. There is
// deliberately NO session wrapped around the draw: a per-frame session diffs
// the whole component every frame, which recorded one undo step per typed
// character.
@(private = "file")
_sq_draw_kind_component :: proc(node: engine.Transform_Handle, key: engine.TypeKey, label: string) {
	if key == engine.INVALID_TYPE_KEY do return
	owned, raw := engine.transform_get_comp_key(node, key)
	if raw == nil do return
	tid := engine.get_typeid_by_type_key(key)
	if tid == nil do return

	inspector.consume_inspector_changed()
	defer if inspector.consume_inspector_changed() {
		engine.component_on_validate(key, raw)
	}
	// Ref pickers mint local ids against the owner's root scene, which they
	// read from the inspector owner stack — and the rows record their undo
	// against this component.
	undo.push_component_owner(owned.handle)
	defer undo.pop_owner()
	c_label := strings.clone_to_cstring(label, context.temp_allocator)
	im.PushID(c_label)
	defer im.PopID()
	drawer := inspector.resolve_property_drawer(tid)
	drawer(raw, tid, c_label)
}

@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
sequencer_preview_install :: proc() {
	preview.register({apply = sequencer_preview_apply, restore = sequencer_preview_restore})
}

// Entering play mode ends the preview: play OWNS the world from here, and a
// scrub posing it every frame would fight the simulation. Fires before the
// state flips, so the tracks quiet against the still-authored world.
//
// The director also REWINDS. preview_end leaves stateful tracks reset (the
// particles track clears its systems), so leaving the playhead where the
// scrub left it would start play mid-timeline against freshly emptied
// effects — they rebuild from nothing while instant tracks snap into place,
// which reads as tracks starting on different frames. From 0 everything
// begins together.
@(phase={key=engine.Phase.ExitingEditMode, mode=Editor})
sequencer_preview_exit_edit_mode :: proc() {
	if !_sq.preview do return
	_sq_preview_end()
	_sq.time = 0
	w := engine.ctx_world()
	if !engine.pool_valid(&w.transforms, engine.Handle(_sq.dir_owner)) do return
	if _, d := engine.transform_get_comp(_sq.dir_owner, seq.PlayableDirector); d != nil {
		seq.director_stop(d)
	}
}

@(menu_item={path="Window/Animation/Sequencer", shortcut=""})
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
		im.TextWrapped("A timeline is the director's subtree: track nodes as children, clip nodes under them. Add Track builds them for you.")
		return
	}
	if owner != _sq.dir_owner {
		// New target: the preview restarts cleanly.
		_sq.dir_owner = owner
		_sq.playing = false
		_sq.time = 0
		_sq.sel_track = -1
	}

	w := engine.ctx_world()
	tracks := seq.director_tracks(d)
	dcomp_owned, _ := engine.transform_get_comp_key(owner, .PlayableDirector)

	// --- Toolbar -------------------------------------------------------------------
	dur := max(seq.director_duration(d, tracks), 0.001)
	playing_mode := engine.application_is_playing()
	// Preview controls only — play mode drives the director itself, so
	// scrubbing it would fight the simulation. Editing stays available.
	im.BeginDisabled(playing_mode)
	if im.Checkbox("Preview", &_sq.preview) {
		if !_sq.preview do _sq.playing = false
	}
	if playing_mode do im.SetItemTooltip("Play mode drives the director")
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
	im.EndDisabled()
	im.SameLine()
	im.Text("%6.2fs / %.2fs", _sq.time, dur)
	im.SameLine()
	im.SetNextItemWidth(90)
	dur_changed := im.DragFloat("##sq_dur", &d.duration, 0.05, 0, 0, "len %.2f")
	im.SetItemTooltip("Duration (0 = last clip end)")
	_sq_field_undo(dcomp_owned.handle, "Timeline Duration", dur_changed)
	im.SameLine()
	{
		// The timeline is scene content: Save saves the owner's scene.
		scene: ^engine.Scene
		if t := engine.pool_get(&w.transforms, engine.Handle(owner)); t != nil do scene = t.scene
		im.BeginDisabled(scene == nil || len(scene.path) == 0)
		if im.Button("Save Scene") {
			if scene != nil do engine.scene_save(scene, scene.path)
		}
		im.EndDisabled()
	}
	im.SameLine()
	if im.SmallButton("Add Track") do im.OpenPopup("sq_add_track")
	if im.BeginPopup("sq_add_track") {
		for desc in seq.track_kinds() {
			if im.Selectable(fmt.ctprintf("%s", desc.label)) do _sq_add_track(owner, desc)
		}
		im.EndPopup()
	}

	// --- Legend | canvas | inspector, splitters between --------------------------
	body_h := im.GetContentRegionAvail().y
	total_w := im.GetContentRegionAvail().x
	rows_h := _SQ_RULER_H + f32(len(tracks)) * _SQ_ROW_H
	_sq.legend_w = clamp(_sq.legend_w, _SQ_MIN_PANE, max(total_w - 2 * _SQ_MIN_PANE, _SQ_MIN_PANE))
	_sq.inspector_w = clamp(_sq.inspector_w, _SQ_MIN_PANE, max(total_w - _sq.legend_w - _SQ_MIN_PANE, _SQ_MIN_PANE))

	if im.BeginChild("##sq_legend", im.Vec2{_sq.legend_w, body_h}) {
		// Rows are pinned to the SAME grid the canvas draws: row i starts at
		// ruler + i*_SQ_ROW_H from the pane top. Stacking widget heights and
		// padding the remainder drifts, because a row's widgets do not add up
		// to exactly _SQ_ROW_H.
		legend_top := im.GetCursorScreenPos().y
		remove_track := engine.Transform_Handle{}
		for &tv, ti in tracks {
			im.PushIDInt(i32(ti))
			row_y := legend_top + _SQ_RULER_H + f32(ti) * _SQ_ROW_H
			// Center the row's widgets in the band. SmallButton — what the
			// row is built from — is text height plus FramePadding.y, NOT a
			// full frame height, so centering on GetFrameHeight() sat the row
			// high.
			row_h := im.GetTextLineHeight() + im.GetStyle().FramePadding.y
			pos := im.GetCursorScreenPos()
			pos.y = row_y + (_SQ_ROW_H - row_h) * 0.5
			im.SetCursorScreenPos(pos)
			comp, tc := _sq_track_comp(&tv)
			if tc == nil {
				im.PopID()
				continue
			}
			// Mute: a speaker icon, lit when audible and dimmed when muted
			// (the state reads at a glance, unlike a checkbox). The push/pop
			// pair must test the SAME value — the click below flips
			// tc.muted, so a re-read at pop time unbalances the style stack.
			was_muted := tc.muted
			if was_muted do im.PushStyleColorImVec4(.Text, im.GetStyleColorVec4(.TextDisabled)^)
			if im.SmallButton(was_muted ? _ICON_VOLUME_OFF : _ICON_VOLUME_UP) {
				_sq_session_begin(comp, "Mute Track")
				tc.muted = !was_muted
				_sq_session_end()
			}
			if was_muted do im.PopStyleColor()
			im.SetItemTooltip(was_muted ? "Unmute" : "Mute")
			im.SameLine()
			// The name row selects the track (and deselects any clip), so the
			// inspector pane and Add Clip act on it without touching a clip.
			if im.Selectable(fmt.ctprintf("%s##trk", tv.name), _sq.sel_track == ti && _sq.sel_clip < 0,
				{}, im.Vec2{im.GetContentRegionAvail().x - 46, 0}) {
				_sq.sel_track = ti
				_sq.sel_clip = -1
			}
			im.SetItemTooltip("%s track", _sq_kind_label(tv.kind))
			im.OpenPopupOnItemClick("track_ctx")
			if im.BeginPopup("track_ctx") {
				if im.Selectable("Add Clip at Playhead") do _sq_add_clip(&tv, ti, _sq.time)
				if im.Selectable("Rename...", false, {.NoAutoClosePopups}) {
					_sq_buf_set(_sq_track_name_buf[:], tv.name)
					im.OpenPopup("track_rename")
				}
				if im.BeginPopup("track_rename") {
					im.SetKeyboardFocusHere()
					enter := im.InputText("##track_name", cstring(raw_data(_sq_track_name_buf[:])),
						len(_sq_track_name_buf), {.EnterReturnsTrue})
					if enter {
						if t := engine.pool_get(&w.transforms, engine.Handle(tv.node)); t != nil {
							e := undo.edit_begin(tv.node, &t.name, typeid_of(string))
							delete(t.name)
							t.name = _sq_clone(_sq_buf_get(_sq_track_name_buf[:]))
							undo.edit_end(&e)
						}
						im.CloseCurrentPopup()
					}
					im.EndPopup()
				}
				if im.Selectable("Remove Track") do remove_track = tv.node
				im.EndPopup()
			}
			im.SameLine()
			if im.SmallButton("+") do _sq_add_clip(&tv, ti, _sq.time)
			im.SetItemTooltip("Add clip")
			im.SameLine()
			if im.SmallButton("x") do remove_track = tv.node
			im.SetItemTooltip("Remove track")
			im.PopID()
		}
		if remove_track != {} {
			undo.record_delete(remove_track)
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
		// Room past the timeline end: clips may live beyond it (a computed
		// duration then grows to include them, an authored one clips them).
		canvas_w := max((dur + _SQ_TAIL_S) * _sq.pps + 120, im.GetContentRegionAvail().x)
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

		// The timeline END: past it the whole canvas dims and a line marks
		// the boundary — clips can sit out here, they just never play.
		end_x := to_x(origin, dur)
		if end_x < origin.x + canvas_w {
			im.DrawList_AddRectFilled(dl, im.Vec2{end_x, origin.y},
				im.Vec2{origin.x + canvas_w, origin.y + rows_h},
				im.GetColorU32ImVec4({0, 0, 0, 0.25}))
		}
		im.DrawList_AddLine(dl, im.Vec2{end_x, origin.y}, im.Vec2{end_x, origin.y + rows_h},
			im.GetColorU32ImVec4({1, 0.85, 0.2, 0.7}), 1)

		step := _sq.pps < 60 ? f32(5) : _sq.pps < 200 ? f32(1) : f32(0.5)
		for t := f32(0); t <= dur + _SQ_TAIL_S + 0.0001; t += step {
			x := to_x(origin, t)
			past := t > dur + 0.0001
			tick_col := past ? im.GetColorU32(.Border, 0.4) : im.GetColorU32(.Border)
			text_col := past ? im.GetColorU32(.TextDisabled, 0.5) : im.GetColorU32(.TextDisabled)
			im.DrawList_AddLine(dl, {x, origin.y + 10}, {x, origin.y + _SQ_RULER_H}, tick_col)
			im.DrawList_AddText(dl, {x + 3, origin.y}, text_col, fmt.ctprintf("%g", t))
		}
		im.SetCursorScreenPos(origin)
		im.InvisibleButton("##sq_ruler", im.Vec2{canvas_w, _SQ_RULER_H})
		if im.IsItemActive() {
			_sq.time = clamp(from_x(origin, im.GetMousePos().x), 0, dur)
			_sq.preview = true
			_sq.playing = false
		}

		// Track rows + clips. Structural clip actions from the context menu
		// defer to after the loops — mutating nodes mid-iteration would
		// invalidate the views.
		act_dup := [2]int{-1, -1}
		act_del := [2]int{-1, -1}
		for &tv, ti in tracks {
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
				_sq_add_clip(&tv, ti, row_t)
			} else if im.IsItemActivated() {
				_sq.sel_track = ti
				_sq.sel_clip = -1
			}
			if im.IsItemHovered({}) && im.IsMouseReleased(.Right) do _sq_ctx_time = row_t
			im.OpenPopupOnItemClick("row_ctx")
			if im.BeginPopup("row_ctx") {
				if im.Selectable("Add Clip Here") do _sq_add_clip(&tv, ti, _sq_ctx_time)
				im.EndPopup()
			}
			im.PopID()

			for &c, ci in tv.clips {
				x0 := to_x(origin, c.start)
				x1 := to_x(origin, c.start + max(c.duration, 0.05))
				r0 := im.Vec2{x0, row_y + 3}
				r1 := im.Vec2{x1, row_y + _SQ_ROW_H - 3}
				selected := _sq.sel_track == ti && _sq.sel_clip == ci
				col := _sq_track_color(tv.kind)
				if tv.muted do col.w *= 0.35
				im.DrawList_AddRectFilled(dl, r0, r1, im.GetColorU32ImVec4(col), 3)
				if selected {
					// Binding order is (rounding, thickness, flags) — unlike native imgui.
					im.DrawList_AddRect(dl, r0, r1, im.GetColorU32ImVec4({1, 0.85, 0.2, 1}), 3, 2)
				}
				// Blend ramps, Unity-style: the weight curve drawn as a line
				// across the clip. Where clips OVERLAP this reads as an X —
				// one ramping down while its neighbour ramps up — because
				// both are drawing the same derived weights
				// (seq.track_clip_weight).
				if c.duration > 0 {
					ramp_col := im.GetColorU32ImVec4({1, 1, 1, 0.5})
					STEPS :: 12
					prev: im.Vec2
					for si in 0 ..= STEPS {
						ct := c.start + c.duration * f32(si) / f32(STEPS)
						cw := seq.track_clip_weight(tv.clips, ci, min(ct, c.start + c.duration - 0.0001))
						pt := im.Vec2{to_x(origin, ct), r1.y - (r1.y - r0.y) * cw}
						if si > 0 do im.DrawList_AddLine(dl, prev, pt, ramp_col)
						prev = pt
					}
				}
				label := c.name
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
				comp, cc := _sq_clip_comp(&c)
				if im.IsItemActivated() {
					_sq.sel_track = ti
					_sq.sel_clip = ci
					_sq.drag = near_l ? .Resize_L : near_r ? .Resize_R : .Move
					_sq.drag_off = from_x(origin, mx) - c.start
					_sq_session_begin(comp, "Clip Edit")
				}
				if im.IsItemActive() && _sq.sel_track == ti && _sq.sel_clip == ci && cc != nil {
					t_mouse := from_x(origin, mx)
					snap :: proc(v: f32) -> f32 { return math.round(v * 10) / 10 }
					switch _sq.drag {
					case .Move:
						cc.start = max(snap(t_mouse - _sq.drag_off), 0)
					case .Resize_L:
						end := cc.start + cc.duration
						cc.start = clamp(snap(t_mouse), 0, end - 0.1)
						cc.duration = end - cc.start
					case .Resize_R:
						cc.duration = max(snap(t_mouse) - cc.start, 0.1)
					case .None:
					}
				}
				if im.IsItemDeactivated() {
					_sq.drag = .None
					_sq_session_end()
				}
				im.PopID()
			}
		}

		if act_dup[0] >= 0 do _sq_duplicate_clip(&tracks[act_dup[0]], &tracks[act_dup[0]].clips[act_dup[1]])
		if act_del[0] >= 0 do _sq_delete_clip(&tracks[act_del[0]].clips[act_del[1]])

		// Playhead over everything.
		px := to_x(origin, _sq.time)
		im.DrawList_AddLine(dl, {px, origin.y}, {px, origin.y + rows_h}, im.GetColorU32ImVec4({1, 0.3, 0.25, 1}), 2)
	}
	im.EndChild()

	// Keyboard: Delete/Backspace removes the selected clip — unless a text
	// field owns the keyboard.
	if im.IsWindowFocused(im.FocusedFlags_RootAndChildWindows) && !im.GetIO().WantTextInput {
		if (im.IsKeyPressed(.Delete) || im.IsKeyPressed(.Backspace)) &&
		   _sq.sel_track >= 0 && _sq.sel_track < len(tracks) {
			if _sq.sel_clip >= 0 && _sq.sel_clip < len(tracks[_sq.sel_track].clips) {
				_sq_delete_clip(&tracks[_sq.sel_track].clips[_sq.sel_clip])
			}
		}
	}

	// --- Inspector pane: the selected clip's fields, one per row -----------------
	im.SameLine(0, 0)
	_sq_splitter("##sq_split_r", true, &_sq.inspector_w, total_w - _sq.legend_w, after = true)
	im.SameLine(0, 0)
	if im.BeginChild("##sq_inspector", im.Vec2{0, body_h}, {.Borders}) {
		_sq_inspector_pane(tracks)
	}
	im.EndChild()
}

// The selected clip's properties, stacked vertically like the object
// inspector — the sequencer's own inspector pane.
@(private = "file")
_sq_inspector_pane :: proc(tracks: []seq.Track_View) {
	if _sq.sel_track < 0 || _sq.sel_track >= len(tracks) {
		im.TextDisabled("No selection.")
		im.TextWrapped("Click a track row or clip. Double-click empty row space to add a clip.")
		return
	}
	tv := &tracks[_sq.sel_track]
	tcomp, tc := _sq_track_comp(tv)
	if tc == nil do return
	{
		im.SeparatorText("Track")
		im.Text("%s", fmt.ctprintf("%s (%s)", tv.name, _sq_kind_label(tv.kind)))
		was_muted := tc.muted
		if was_muted do im.PushStyleColorImVec4(.Text, im.GetStyleColorVec4(.TextDisabled)^)
		if im.SmallButton(was_muted ? _ICON_VOLUME_OFF : _ICON_VOLUME_UP) {
			_sq_session_begin(tcomp, "Mute Track")
			tc.muted = !was_muted
			_sq_session_end()
		}
		if was_muted do im.PopStyleColor()
		im.SetItemTooltip(was_muted ? "Unmute" : "Mute")
		im.Text("%d clips", i32(len(tv.clips)))
		// The kind's own fields (its target, its options) — tags drive the
		// pickers, so nothing here knows what a kind needs.
		_sq_draw_kind_component(tv.node, tv.kind, "Track Target")
	}
	if _sq.sel_clip < 0 || _sq.sel_clip >= len(tv.clips) {
		im.SeparatorText("Clip")
		im.TextDisabled("No clip selected.")
		return
	}
	{
		c := &tv.clips[_sq.sel_clip]
		comp, cc := _sq_clip_comp(c)
		if cc == nil do return
		im.SeparatorText("Clip")

		// The clip's name is its NODE name — what the marker hook fires with,
		// and the block's label. The buffer reloads when the selection
		// changes, the node takes the value on commit (one undo step).
		if _sq_clip_name_for != {_sq.sel_track, _sq.sel_clip} {
			_sq_clip_name_for = {_sq.sel_track, _sq.sel_clip}
			_sq_buf_set(_sq_clip_name_buf[:], c.name)
		}
		im.SetNextItemWidth(-1)
		im.InputTextWithHint("##c_name", "Name", cstring(raw_data(_sq_clip_name_buf[:])), len(_sq_clip_name_buf))
		if im.IsItemDeactivatedAfterEdit() {
			w := engine.ctx_world()
			if t := engine.pool_get(&w.transforms, engine.Handle(c.node)); t != nil {
				e := undo.edit_begin(c.node, &t.name, typeid_of(string))
				delete(t.name)
				t.name = _sq_clone(_sq_buf_get(_sq_clip_name_buf[:]))
				undo.edit_end(&e)
			}
		}

		row :: proc(label: cstring) {
			im.TextUnformatted(label)
			im.SameLine(90)
			im.SetNextItemWidth(-1)
		}
		row("Start")
		_sq_field_undo(comp, "Clip Start", im.DragFloat("##c_start", &cc.start, 0.02, 0, 0, "%.2f s"))
		row("Duration")
		_sq_field_undo(comp, "Clip Duration", im.DragFloat("##c_dur", &cc.duration, 0.02, 0, 0, "%.2f s"))
		row("Ease In")
		_sq_field_undo(comp, "Clip Ease", im.DragFloat("##c_ein", &cc.ease_in, 0.01, 0, 0, "%.2f s"))
		row("Ease Out")
		_sq_field_undo(comp, "Clip Ease", im.DragFloat("##c_eout", &cc.ease_out, 0.01, 0, 0, "%.2f s"))
		row("Speed")
		_sq_field_undo(comp, "Clip Speed", im.DragFloat("##c_speed", &cc.speed, 0.01, 0, 0, "x%.2f"))
		im.SetItemTooltip("0 behaves as 1")

		// The clip's payload lives on the kind's clip component — its `ext:`
		// tags filter the asset picker without the window naming any kind.
		if desc, has := seq.track_desc(tv.kind); has {
			_sq_draw_kind_component(c.node, desc.clip_key, "Clip Payload")
			if desc.track_key == .TrackControl {
				im.TextWrapped("Nest a timeline prefab under this clip's node — the clip plays its director at the clip-local time.")
			}
		}

		im.Spacing()
		if im.Button("Duplicate", {-1, 0}) do _sq_duplicate_clip(tv, c)
		if im.Button("Delete", {-1, 0}) do _sq_delete_clip(c)
	}
}

@(private = "file")
_sq_track_color :: proc(kind: engine.TypeKey) -> im.Vec4 {
	#partial switch kind {
	case .TrackAnimation:  return {0.30, 0.50, 0.80, 0.9}
	case .TrackAudio:      return {0.75, 0.55, 0.25, 0.9}
	case .TrackActivation: return {0.40, 0.70, 0.40, 0.9}
	case .TrackParticles:  return {0.65, 0.40, 0.75, 0.9}
	case .TrackControl:    return {0.35, 0.65, 0.70, 0.9}
	}
	return {0.5, 0.5, 0.5, 0.9}
}

// --- Preview apply/restore (main loop hooks) --------------------------------------------

// Pose the world at the playhead for the scene/game render only — bracketed
// with sequencer_preview_restore around the render in main.odin, like the
// animation scrub preview.
sequencer_preview_apply :: proc() {
	if !_sq.preview do return
	// Play owns the world — the director ticks itself there.
	if engine.application_is_playing() {
		_sq_preview_end()
		return
	}
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

	playing_step := _sq.playing
	if playing_step {
		tracks := seq.director_tracks(d)
		dur := max(seq.director_duration(d, tracks), 0.001)
		_sq.time += im.GetIO().DeltaTime
		if _sq.time >= dur do _sq.time = 0
	}

	// Play advances with real crossings (audio sounds, like Unity's Timeline
	// preview); a paused or dragged playhead is a silent scrub.
	if playing_step {
		seq.director_preview_step(d, _sq.time)
	} else {
		seq.director_set_time(d, _sq.time)
	}
	_sq.applied = true
}

sequencer_preview_restore :: proc() {
	if !_sq.applied do return
	_sq.applied = false
	// Track kinds restore whatever they drove (poses, activation, audio,
	// particles) — the window knows no kind by name. While PLAYING this is
	// the per-frame render restore: persistent preview effects (the audio
	// voice) survive it, and quiet for real when playing stops.
	_, d := engine.transform_get_comp(_sq.dir_owner, seq.PlayableDirector)
	if d != nil do seq.director_preview_end(d, _sq.playing)
}

// The preview stops being valid (target gone, window retargeted): let every
// track quiet what it was driving.
@(private = "file")
_sq_preview_end :: proc() {
	_sq.preview = false
	_sq.playing = false
	// Consume the pending per-frame restore: the tracks are being released
	// HERE, and letting restore_all run again afterwards would write
	// bind-time defaults into whatever world exists by then (entering play
	// mode mid-frame is exactly that case — the restore landed in the
	// simulated world and pinned the animation target's pose).
	_sq.applied = false
	w := engine.ctx_world()
	if !engine.pool_valid(&w.transforms, engine.Handle(_sq.dir_owner)) do return
	_, d := engine.transform_get_comp(_sq.dir_owner, seq.PlayableDirector)
	if d != nil do seq.director_preview_end(d)
}
