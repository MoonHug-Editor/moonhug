package animation_editor

// The dopesheet mode of the Animation window: key diamonds per row, summary
// keys on Object rows and split rows, key presses and drags, and box
// selection.

import "base:runtime"
import im "moonhug:external/odin-imgui"
import anim "moonhug:packages/animation"
import "moonhug:editor/inspector"
import "moonhug:editor/undo"

@(private = "file") _ANIM_KEY_R :: f32(4)  // key diamond half-size

// --- Dopesheet ------------------------------------------------------------------------

@(private)
_pv_key_hit_x :: proc(times: []f32, mx, tx0, pps: f32) -> int {
	best := -1
	best_d := _ANIM_HIT
	for t, k in times {
		d := abs(tx0 + t * pps - mx)
		if d < best_d {
			best_d = d
			best = k
		}
	}
	return best
}

// The channels a row's summary keys stand for: an Object row's target
// channels, a split Channel row's lane channels. Nil for a row with keys of
// its own (`ok` false). Temp-allocated.
@(private = "file")
_pv_summary_chans :: proc(clip: ^anim.AnimationClip, r: Sheet_Row) -> (chans: []int, ok: bool) {
	#partial switch r.kind {
	case .Object:
		return sheet_target_channels(clip, r.target, context.temp_allocator), true
	case .Channel:
		if r.split do return _pv_group(clip, r.ch), true
	}
	return nil, false
}

// The keys of `chans` the summary key under `mx` stands for, nil when no
// summary key is there. Temp-allocated.
@(private = "file")
_pv_summary_hit :: proc(clip: ^anim.AnimationClip, chans: []int, mx, tx0, pps: f32) -> []Sheet_Key {
	times := sheet_keys_times(clip, chans, context.temp_allocator)
	j := _pv_key_hit_x(times, mx, tx0, pps)
	if j < 0 do return nil
	return sheet_keys_at(clip, chans, times, j, context.temp_allocator)
}

// Per summary time over `chans`: every key it stands for is selected.
// Temp-allocated, parallel to `times`.
@(private = "file")
_pv_summary_selected :: proc(clip: ^anim.AnimationClip, chans: []int, times: []f32) -> []bool {
	all := make([]bool, len(times), context.temp_allocator)
	if len(_av.sel) == 0 do return all
	for &v in all do v = true
	for ci in chans {
		c := &clip.channels[ci]
		for kt, k in c.times {
			if j := sheet_object_key_index(times, kt); j >= 0 && !_pv_sel_has(ci, k) do all[j] = false
		}
	}
	return all
}

// A summary key: a dimmer diamond with an outline, so it reads apart from a
// property row's keys.
@(private = "file")
_pv_draw_summary_key :: proc(dl: ^im.DrawList, kx, ky: f32, sel: bool) {
	r := sel ? _ANIM_KEY_R + 1 : _ANIM_KEY_R
	top, right, bottom, left := im.Vec2{kx, ky - r}, im.Vec2{kx + r, ky}, im.Vec2{kx, ky + r}, im.Vec2{kx - r, ky}
	fill := sel ? im.GetColorU32(.CheckMark) : im.GetColorU32(.TextDisabled)
	im.DrawList_AddQuadFilled(dl, top, right, bottom, left, fill)
	im.DrawList_AddQuad(dl, top, right, bottom, left, im.GetColorU32(.Text), 1)
}

// Adds the keys of channel `ci` inside the band [rmin, rmax] in x to the
// selection. A key already selected (a property row and its Lane rows in the
// same band) is added once.
@(private = "file")
_pv_box_add_channel :: proc(clip: ^anim.AnimationClip, ci: int, rmin, rmax: im.Vec2, tx0, pps: f32) {
	for t, k in clip.channels[ci].times {
		kx := tx0 + t * pps
		if kx < rmin.x || kx > rmax.x || _pv_sel_has(ci, k) do continue
		_pv_sel_add(ci, k)
	}
}

@(private)
_pv_sheet_dopesheet :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, dl: ^im.DrawList, f: _Sheet_Frame) {
	rows, rows_y, x0, x1, tx0, pps := f.rows, f.rows_y, f.x0, f.x1, f.tx0, f.pps
	hovered, mp, row_at := f.hovered, f.mp, f.row_at
	// Row stripes + keys. An Object row shows a summary key at every time any
	// of its channels has one, the hidden ones included. A split Channel row
	// does the same over its lane channels.
	for r, i in rows {
		ry := rows_y + f32(i) * _ANIM_ROW_H
		ky := ry + _ANIM_ROW_H * 0.5
		if r.kind == .Object {
			im.DrawList_AddRectFilled(dl, im.Vec2{x0, ry}, im.Vec2{x1, ry + _ANIM_ROW_H}, im.GetColorU32(.FrameBg, 0.6))
		} else if i % 2 == 1 {
			im.DrawList_AddRectFilled(dl, im.Vec2{x0, ry}, im.Vec2{x1, ry + _ANIM_ROW_H}, im.GetColorU32(.FrameBg, 0.25))
		}
		if chans, ok := _pv_summary_chans(clip, r); ok {
			times := sheet_keys_times(clip, chans, context.temp_allocator)
			sel := _pv_summary_selected(clip, chans, times)
			for t, j in times do _pv_draw_summary_key(dl, tx0 + t * pps, ky, sel[j])
			continue
		}
		// A Lane row shows the row's keys in its lane's colour.
		key_col := im.GetColorU32(.Text)
		if r.kind == .Lane {
			comp_cols := _ANIM_COMP_COLS
			key_col = im.GetColorU32ImVec4(comp_cols[r.lane])
		}
		for t, k in clip.channels[r.ch].times {
			kx := tx0 + t * pps
			sel := _pv_sel_has(r.ch, k)
			col := sel ? im.GetColorU32(.CheckMark) : key_col
			kr := sel ? _ANIM_KEY_R + 1 : _ANIM_KEY_R
			im.DrawList_AddQuadFilled(dl,
				im.Vec2{kx, ky - kr}, im.Vec2{kx + kr, ky},
				im.Vec2{kx, ky + kr}, im.Vec2{kx - kr, ky}, col)
		}
	}

	// The row under the pointer: an Object row, or a property row's channel. A
	// Lane row stands for its channel: its keys are the row's keys.
	// A summary row (an Object row, a split Channel row) hit-tests its
	// summary keys over `sum_chans`.
	obj_row := row_at >= 0 && rows[row_at].kind == .Object
	row_ch := row_at >= 0 && !obj_row ? rows[row_at].ch : -1
	sum_chans: []int
	sum_row := false
	if row_at >= 0 do sum_chans, sum_row = _pv_summary_chans(clip, rows[row_at])

	if im.IsItemActivated() {
		in_canvas := mp.x >= x0
		// A summary key selects every key it stands for and drags them, as a
		// property row's key does.
		sum_keys: []Sheet_Key
		if sum_row && in_canvas do sum_keys = _pv_summary_hit(clip, sum_chans, mp.x, tx0, pps)
		if len(sum_keys) > 0 {
			if _pv_additive() {
				_pv_sel_toggle_keys(sum_keys)
			} else {
				_pv_pick_keys(sum_keys)
				_pv_drag_begin(doc, clip, (mp.x - tx0) / pps, comp = -1)
			}
		} else if obj_row {
			// The name selects nothing: its arrow is the sheet's (collapse),
			// the rest of it is inert.
			if in_canvas {
				// Empty canvas on an Object row: rubber-band, the channel stays.
				_av.sel_key = -1
				_pv_sel_clear()
				_av.box = true
				_av.box_from = mp
			}
		} else {
			k := -1
			if in_canvas && row_ch >= 0 && !sum_row do k = _pv_key_hit_x(clip.channels[row_ch].times[:], mp.x, tx0, pps)
			switch {
			case k >= 0 && _pv_additive():
				// Add to or drop from the selection, no drag: a modifier click is
				// for building a set, not moving it.
				_pv_sel_toggle(row_ch, k)
			case k >= 0:
				// Dragging a key that is already selected moves the whole
				// selection. Grabbing an unselected one selects just it.
				_pv_pick_key(row_ch, k)
				_pv_drag_begin(doc, clip, (mp.x - tx0) / pps, comp = -1)
			case in_canvas:
				// Empty canvas, on a track row or below the last one: rubber-band
				// a new selection. The row under the press only sets the channel
				// when there is one, so a band started below the tracks leaves
				// the current channel alone.
				if row_ch >= 0 do _av.sel_ch = row_ch
				_av.sel_key = -1
				_pv_sel_clear()
				_av.box = true
				_av.box_from = mp
			case row_ch >= 0:
				// Left panel: pick the channel.
				_av.sel_ch = row_ch
				_av.sel_key = -1
				_pv_sel_clear()
			}
		}
	}
	if im.IsItemClicked(.Right) && mp.x >= x0 {
		// Right-clicking outside the selection retargets it, so the menu
		// always acts on what is under the cursor.
		if sum_row {
			if keys := _pv_summary_hit(clip, sum_chans, mp.x, tx0, pps); len(keys) > 0 {
				_pv_pick_keys(keys)
				im.OpenPopup("##anim_key_ctx")
			}
		} else if row_ch >= 0 {
			if k := _pv_key_hit_x(clip.channels[row_ch].times[:], mp.x, tx0, pps); k >= 0 {
				_pv_pick_key(row_ch, k)
				im.OpenPopup("##anim_key_ctx")
			}
		}
	}
	// Double-click on empty canvas of a property row: add a key there
	// (sampled, shape-preserving). An Object row has no channel to key. A
	// split row keys every lane channel, one undo step.
	if hovered && row_ch >= 0 && sum_row && mp.x >= x0 && im.IsMouseDoubleClicked(.Left) {
		if len(_pv_summary_hit(clip, sum_chans, mp.x, tx0, pps)) == 0 {
			_av.box = false
			t := _pv_snap_time(clip, (mp.x - tx0) / pps)
			_pv_edit_hold()
			for ci in sum_chans do _pv_add_key(doc, clip, ci, t)
			_pv_edit_release()
			if undo.edit_session_active(&_pv_session) do _pv_edit_commit(doc)
		}
	} else if hovered && row_ch >= 0 && mp.x >= x0 && im.IsMouseDoubleClicked(.Left) {
		if _pv_key_hit_x(clip.channels[row_ch].times[:], mp.x, tx0, pps) < 0 {
			_av.box = false // the press that opened the band was this click
			_pv_add_key(doc, clip, row_ch, _pv_snap_time(clip, (mp.x - tx0) / pps))
		}
	}

	// --- Box select: every key inside the band, across rows. An Object row in
	// the band takes the keys of all its channels, hidden ones included, and
	// its property rows then add nothing more.
	if _av.box {
		rmin := im.Vec2{min(_av.box_from.x, mp.x), min(_av.box_from.y, mp.y)}
		rmax := im.Vec2{max(_av.box_from.x, mp.x), max(_av.box_from.y, mp.y)}
		im.DrawList_AddRectFilled(dl, rmin, rmax, im.GetColorU32(.Header, 0.35))
		im.DrawList_AddRect(dl, rmin, rmax, im.GetColorU32(.CheckMark))

		_pv_sel_clear()
		object_in_band := false // the Object row the rows below belong to
		for r, i in rows {
			ky := rows_y + f32(i) * _ANIM_ROW_H + _ANIM_ROW_H * 0.5
			in_band := ky >= rmin.y && ky <= rmax.y
			if r.kind == .Object {
				object_in_band = in_band
				if !in_band do continue
				for &c, ci in clip.channels {
					if c.target == r.target do _pv_box_add_channel(clip, ci, rmin, rmax, tx0, pps)
				}
				continue
			}
			if !in_band || object_in_band do continue
			// A split row takes the keys of all its lane channels.
			if chans, ok := _pv_summary_chans(clip, r); ok {
				for ci in chans do _pv_box_add_channel(clip, ci, rmin, rmax, tx0, pps)
			} else {
				_pv_box_add_channel(clip, r.ch, rmin, rmax, tx0, pps)
			}
		}
		// Primary is the first key the band caught, so the value footer has
		// something to edit.
		if len(_av.sel) > 0 {
			_av.sel_ch = _av.sel[0].ch
			_av.sel_key = _av.sel[0].key
		} else {
			_av.sel_key = -1
		}
		if !im.IsMouseDown(.Left) do _av.box = false
	}
}

// Opens the undo session for a key drag and records where every selected key
// started, so the move is one delta applied to the group.
@(private)
_pv_drag_begin :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, from: f32, comp: int) {
	if doc == nil do return // read-only: the press only selects
	_pv_edit_begin(doc)
	_av.drag_key = true
	_av.drag_press = im.GetMousePos()
	_av.drag_live = false
	_av.drag_comp = comp
	_av.drag_from = _pv_snap_time(clip, from)
	// Cross-frame state, so it allocates from the default allocator whatever
	// the caller's context holds, as the selection does.
	if _av.drag_t0.allocator.procedure == nil do _av.drag_t0.allocator = runtime.default_allocator()
	clear(&_av.drag_t0)
	for r in _av.sel do append(&_av.drag_t0, clip.channels[r.ch].times[r.key])
}
