package animation_editor

// The curves mode of the Animation window: the selected property's channels
// as sampled curves over a value axis, with key squares and the tangent
// handles of Free keys, and their presses and drags.

import "core:fmt"
import "core:math/linalg"
import im "moonhug:external/odin-imgui"
import anim "moonhug:packages/animation"
import "moonhug:editor/inspector"
import "moonhug:editor/undo"

@(private = "file") _ANIM_TAN_LEN :: f32(40) // a tangent handle's distance from its key, in pixels
@(private = "file") _ANIM_TAN_R :: f32(3.5)  // a tangent handle's circle radius

// --- Curves ---------------------------------------------------------------------------

// Value range of the curve area this frame (set during draw, read by the drag
// update). Range follows the selected channel's keys and its Free keys'
// tangent handles, with 10% padding.
@(private = "file")
_curve_vmin, _curve_vmax: f32

@(private = "file")
_pv_curve_v_to_y :: proc(v, rows_y, body_h: f32) -> f32 {
	span := max(_curve_vmax - _curve_vmin, 0.0001)
	return rows_y + 6 + (1 - (v - _curve_vmin) / span) * (body_h - 12)
}

@(private)
_pv_curve_y_to_v :: proc(y, rows_y, body_h: f32) -> f32 {
	span := max(_curve_vmax - _curve_vmin, 0.0001)
	return _curve_vmin + (1 - (y - rows_y - 6) / max(body_h - 12, 1)) * span
}

// Pixels per value unit on the curve area's y axis.
@(private = "file")
_pv_curve_vpx :: proc(body_h: f32) -> f32 {
	return max(body_h - 12, 1) / max(_curve_vmax - _curve_vmin, 0.0001)
}

// Whether the curve view draws tangent handles for a channel: a float row
// whose keys can be Free (a Rotation row slerps and has no tangents).
@(private = "file")
_pv_curve_has_handles :: proc(ch: ^anim.Animation_Channel) -> bool {
	return .Free in channel_modes_allowed(ch)
}

// The screen point of a tangent handle of key `k`, lane `c`: the out handle
// when `out`, else the in handle. `tin` and `tout` are the key's tangents.
@(private = "file")
_pv_tan_handle_pos :: proc(key_pt: im.Vec2, tin, tout: [4]f32, c: int, out: bool, pps, vpx: f32) -> im.Vec2 {
	if out {
		d := tangent_handle_offset(tout[c], pps, vpx, _ANIM_TAN_LEN)
		return {key_pt.x + d.x, key_pt.y + d.y}
	}
	d := tangent_handle_offset(tin[c], pps, vpx, _ANIM_TAN_LEN)
	return {key_pt.x - d.x, key_pt.y - d.y}
}

// Ends a tangent handle drag: records the undo step, or drops the session
// when the key it edited went away.
@(private)
_pv_tan_drag_end :: proc(doc: ^inspector.Asset_Doc, commit: bool) {
	_av.drag_tan = false
	if commit && doc != nil {
		_pv_edit_commit(doc)
	} else {
		undo.edit_session_abort(&_pv_session)
	}
}

@(private)
_pv_sheet_curves :: proc(
	doc: ^inspector.Asset_Doc,
	clip: ^anim.AnimationClip,
	dl: ^im.DrawList,
	rows: []Sheet_Row,
	rows_y, body_h, x0, x1, tx0, pps: f32,
	mp: im.Vec2,
	row_at: int,
) {
	// Left-panel click on a property row selects the channel whose curves
	// show. An Object row plots nothing.
	if im.IsItemActivated() && mp.x < x0 && row_at >= 0 && rows[row_at].kind != .Object {
		_av.sel_ch = rows[row_at].ch
		_av.sel_key = -1
		_pv_sel_clear()
	}

	if _av.sel_ch < 0 || _av.sel_ch >= len(clip.channels) {
		if _av.drag_tan do _pv_tan_drag_end(doc, false)
		im.DrawList_AddText(dl, im.Vec2{x0 + 12, rows_y + 8}, im.GetColorU32(.TextDisabled), "Select a property to edit its curves.")
		return
	}
	ch := &clip.channels[_av.sel_ch]
	if !anim.animation_channel_is_float(ch) {
		if _av.drag_tan do _pv_tan_drag_end(doc, false)
		im.DrawList_AddText(dl, im.Vec2{x0 + 12, rows_y + 8}, im.GetColorU32(.TextDisabled), "This property holds discrete keys: it has no curve.")
		return
	}
	vals := anim.animation_channel_floats(ch)
	ncomp := _pv_ch_ncomp(ch)
	handles := _pv_curve_has_handles(ch)
	// Only the lanes the row animates plot, take handles and take presses.
	off := _pv_lanes_off(ch)
	// Every channel of the property plots: one for a joined row, one per
	// lane for a split row. They share kind, lane count and handles.
	group := _pv_group(clip, _av.sel_ch)

	// Freeze the value range while dragging — a range that follows the edited
	// value makes the curve chase the cursor.
	if !_av.drag_key && !_av.drag_tan {
		vmin, vmax := max(f32), min(f32)
		for gi in group {
			gch := &clip.channels[gi]
			goff := _pv_lanes_off(gch)
			for v in anim.animation_channel_floats(gch) {
				for c in 0 ..< ncomp {
					if c in goff do continue
					vmin = min(vmin, v[c])
					vmax = max(vmax, v[c])
				}
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
		// The range takes in the Free keys' handle points too, so a steep
		// handle on a flat curve is not clipped away. A handle's value depends
		// on the range it is drawn in, so the range settles over a few passes.
		if handles {
			for _ in 0 ..< 3 {
				vpx := _pv_curve_vpx(body_h)
				hmin, hmax := vmin, vmax
				for gi in group {
					gch := &clip.channels[gi]
					gvals := anim.animation_channel_floats(gch)
					goff := _pv_lanes_off(gch)
					for k in 0 ..< len(gch.times) {
						if anim._animation_key_mode(gch, k) != .Free do continue
						tin, tout := anim._animation_key_tangents(gch, gvals[:], k)
						for c in 0 ..< ncomp {
							if c in goff do continue
							dout := tangent_handle_offset(tout[c], pps, vpx, _ANIM_TAN_LEN)
							din := tangent_handle_offset(tin[c], pps, vpx, _ANIM_TAN_LEN)
							hi_v := gvals[k][c] - dout.y / vpx
							lo_v := gvals[k][c] + din.y / vpx
							hmin = min(hmin, hi_v, lo_v)
							hmax = max(hmax, hi_v, lo_v)
						}
					}
				}
				hpad := (hmax - hmin) * 0.1
				_curve_vmin, _curve_vmax = hmin - hpad, hmax + hpad
			}
		}
	}
	vpx := _pv_curve_vpx(body_h)

	// A tangent handle drag: the dragged tangent follows the pointer, Shift
	// sets the other side to the same slope (a smooth joint). Updated before
	// drawing, so the curve shows this frame's tangent.
	if _av.drag_tan {
		k, c := _av.tan_key, _av.tan_comp
		switch {
		case doc == nil || !handles || k < 0 || k >= len(ch.times) || c >= ncomp || c in off || anim._animation_key_mode(ch, k) != .Free:
			_pv_tan_drag_end(doc, false)
		case im.IsMouseDown(.Left):
			key_pt := im.Vec2{tx0 + ch.times[k] * pps, _pv_curve_v_to_y(vals[k][c], rows_y, body_h)}
			m := tangent_from_handle({mp.x - key_pt.x, mp.y - key_pt.y}, pps, vpx, _av.tan_out)
			tin, tout := anim._animation_key_tangents(ch, vals[:], k)
			joint := im.GetIO().KeyShift
			if _av.tan_out {
				tout[c] = m
				if joint do tin[c] = m
			} else {
				tin[c] = m
				if joint do tout[c] = m
			}
			{
				// A key past the end of `tangents` grows it, in the document.
				context.allocator = inspector.doc_alloc()
				channel_set_key_tangents(ch, k, tin, tout)
			}
			_pv_mark_edited(doc)
		case:
			_pv_tan_drag_end(doc, true)
		}
	}

	// The handle under the pointer: the dragged one, else the nearest within
	// the hit radius, across the group's channels. Handles take a press
	// before keys do.
	hov_ch, hov_k, hov_c, hov_out := -1, -1, -1, false
	if _av.drag_tan {
		hov_ch, hov_k, hov_c, hov_out = _av.sel_ch, _av.tan_key, _av.tan_comp, _av.tan_out
	} else if handles && im.IsItemHovered() && mp.x >= x0 {
		best_d := _ANIM_HIT
		for gi in group {
			gch := &clip.channels[gi]
			gvals := anim.animation_channel_floats(gch)
			goff := _pv_lanes_off(gch)
			for t, k in gch.times {
				if anim._animation_key_mode(gch, k) != .Free do continue
				tin, tout := anim._animation_key_tangents(gch, gvals[:], k)
				for c in 0 ..< ncomp {
					if c in goff do continue
					key_pt := im.Vec2{tx0 + t * pps, _pv_curve_v_to_y(gvals[k][c], rows_y, body_h)}
					for out in ([2]bool{false, true}) {
						hp := _pv_tan_handle_pos(key_pt, tin, tout, c, out, pps, vpx)
						d := max(abs(hp.x - mp.x), abs(hp.y - mp.y))
						if d < best_d {
							best_d = d
							hov_ch, hov_k, hov_c, hov_out = gi, k, c, out
						}
					}
				}
			}
		}
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
	for gi in group {
		gch := &clip.channels[gi]
		gvals := anim.animation_channel_floats(gch)
		goff := _pv_lanes_off(gch)
		for c in 0 ..< ncomp {
			if c in goff do continue
			col := im.GetColorU32ImVec4(comp_cols[c])
			pts := make([dynamic]im.Vec2, context.temp_allocator)
			for x := tx0; x <= x1 - _ANIM_PAD_X + 3; x += 3 {
				v := anim._animation_channel_sample(gch, (x - tx0) / pps)
				append(&pts, im.Vec2{x, _pv_curve_v_to_y(v[c], rows_y, body_h)})
			}
			if len(pts) >= 2 {
				im.DrawList_AddPolyline(dl, raw_data(pts[:]), i32(len(pts)), col, 1.5)
			}
			// Tangent handles of the Free keys, under the key squares. The
			// hovered or dragged handle draws brighter.
			if handles {
				bright := im.GetColorU32ImVec4(linalg.lerp(comp_cols[c], im.Vec4{1, 1, 1, 1}, 0.55))
				dim := im.GetColorU32ImVec4(im.Vec4{comp_cols[c].x, comp_cols[c].y, comp_cols[c].z, 0.75})
				for t, k in gch.times {
					if anim._animation_key_mode(gch, k) != .Free do continue
					tin, tout := anim._animation_key_tangents(gch, gvals[:], k)
					key_pt := im.Vec2{tx0 + t * pps, _pv_curve_v_to_y(gvals[k][c], rows_y, body_h)}
					for out in ([2]bool{false, true}) {
						hp := _pv_tan_handle_pos(key_pt, tin, tout, c, out, pps, vpx)
						hot := gi == hov_ch && k == hov_k && c == hov_c && out == hov_out
						hcol := hot ? bright : dim
						im.DrawList_AddLine(dl, key_pt, hp, hcol, 1)
						im.DrawList_AddCircleFilled(dl, hp, hot ? _ANIM_TAN_R + 1 : _ANIM_TAN_R, hcol)
					}
				}
			}
			for t, k in gch.times {
				kx := tx0 + t * pps
				ky := _pv_curve_v_to_y(gvals[k][c], rows_y, body_h)
				sel := gi == _av.sel_ch && k == _av.sel_key && c == _av.drag_comp
				r := sel ? f32(4) : f32(3)
				im.DrawList_AddRectFilled(dl, im.Vec2{kx - r, ky - r}, im.Vec2{kx + r, ky + r}, sel ? im.GetColorU32(.CheckMark) : col)
			}
		}
	}
	im.DrawList_PopClipRect(dl)

	// Press on a tangent handle: drag edits that tangent. It selects the key,
	// and a read-only clip only selects.
	if im.IsItemActivated() && mp.x >= x0 && hov_k >= 0 && !_av.drag_tan {
		if !_pv_sel_has(hov_ch, hov_k) do _pv_sel_set(hov_ch, hov_k)
		_av.sel_ch = hov_ch
		_av.sel_key = hov_k
		if doc != nil {
			_pv_edit_begin(doc)
			_av.drag_tan = true
			_av.tan_key, _av.tan_comp, _av.tan_out = hov_k, hov_c, hov_out
		}
	} else if im.IsItemActivated() && mp.x >= x0 {
		// Press on a key square: drag edits (time, value[comp]). The key's
		// channel becomes the selected channel.
		best_ch, best_k, best_c := -1, -1, -1
		best_d := _ANIM_HIT
		for gi in group {
			gch := &clip.channels[gi]
			gvals := anim.animation_channel_floats(gch)
			goff := _pv_lanes_off(gch)
			for t, k in gch.times {
				kx := tx0 + t * pps
				for c in 0 ..< ncomp {
					if c in goff do continue
					ky := _pv_curve_v_to_y(gvals[k][c], rows_y, body_h)
					d := max(abs(kx - mp.x), abs(ky - mp.y))
					if d < best_d {
						best_d = d
						best_ch, best_k, best_c = gi, k, c
					}
				}
			}
		}
		if best_k >= 0 {
			if _pv_additive() {
				_pv_sel_toggle(best_ch, best_k)
			} else {
				// As in the dopesheet: dragging a selected key moves the
				// group, an unselected one becomes the selection.
				if !_pv_sel_has(best_ch, best_k) do _pv_sel_set(best_ch, best_k)
				_av.sel_ch = best_ch
				_av.sel_key = best_k
				_pv_drag_begin(doc, clip, (mp.x - tx0) / pps, comp = best_c)
			}
		} else {
			_av.sel_key = -1
			_pv_sel_clear()
		}
	}
	if im.IsItemClicked(.Right) && mp.x >= x0 {
		// The selected channel first, then the rest of the group.
		hit_ch, hit_k := _av.sel_ch, _pv_key_hit_x(ch.times[:], mp.x, tx0, pps)
		for gi in group {
			if hit_k >= 0 do break
			if gi == _av.sel_ch do continue
			hit_ch, hit_k = gi, _pv_key_hit_x(clip.channels[gi].times[:], mp.x, tx0, pps)
		}
		if hit_k >= 0 {
			if !_pv_sel_has(hit_ch, hit_k) do _pv_sel_set(hit_ch, hit_k)
			_av.sel_ch = hit_ch
			_av.sel_key = hit_k
			im.OpenPopup("##anim_key_ctx")
		}
	}
}
