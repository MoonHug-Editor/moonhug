package animation_editor

// The selected-key footer of the Animation window: the primary key's time,
// mode and values as fields, and a Delete button for the selection.

import "core:fmt"
import im "moonhug:external/odin-imgui"
import anim "moonhug:packages/animation"
import "moonhug:editor/inspector"

// --- Selected-key footer ----------------------------------------------------------------

@(private)
_pv_draw_key_footer :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip) {
	ch := &clip.channels[_av.sel_ch]
	k := _av.sel_key

	// A read-only clip shows the key's values without letting them change.
	im.BeginDisabled(doc == nil)
	defer im.EndDisabled()

	im.AlignTextToFramePadding()
	im.TextUnformatted(fmt.ctprintf("Key %d   t", k))
	im.SameLine()
	im.SetNextItemWidth(70)
	lo, hi := _pv_drag_time_bounds(ch, k, clip.length)
	_pv_field_undo(doc, clip, im.DragFloat("##anim_key_t", &ch.times[k], 0.002, lo, hi, "%.3f"))
	im.SameLine()
	_pv_draw_mode_combo(doc, clip, ch, k)

	// A key of a string row shows a text field and a key of a reference row
	// the asset picker, both setting this key's value. A key of an int row,
	// or of a row that no longer resolves, shows its value as text.
	if !anim.animation_channel_is_float(ch) {
		im.SameLine()
		kind, kok := _pv_row_kind(ch)
		if kok && (kind == .Ref || kind == .Text) {
			if v, edited := _pv_discrete_field(ch, kind, anim.animation_channel_value(ch, k), 200); edited {
				_pv_set_key_value(doc, clip, _av.sel_ch, k, v)
			}
		} else {
			im.TextUnformatted(fmt.ctprintf("%s", _pv_value_text(anim.animation_channel_value(ch, k))))
		}
	}

	// A rotation key shows three euler angles, written back as a quaternion.
	if _pv_ch_is_rotation(ch) {
		vals := anim.animation_channel_floats(ch)
		euler := _pv_rot_to_euler(vals[k])
		axis_names := [3]cstring{"x", "y", "z"}
		for c in 0 ..< 3 {
			im.SameLine()
			im.TextUnformatted(axis_names[c])
			im.SameLine()
			im.SetNextItemWidth(70)
			changed := im.DragFloat(fmt.ctprintf("##anim_key_e%d", c), &euler[c], 0.5, 0, 0, "%.1f")
			// Opened before the write, so the session holds the key from
			// before this frame's change.
			if im.IsItemActivated() do _pv_edit_begin(doc)
			if changed do vals[k] = _pv_rot_from_euler(euler)
			_pv_field_undo(doc, clip, changed)
		}
	}

	ncomp := _pv_ch_is_rotation(ch) || !anim.animation_channel_is_float(ch) ? 0 : _pv_ch_ncomp(ch)
	comp_names := [4]cstring{"x", "y", "z", "w"}
	off := _pv_lanes_off(ch)
	for c in 0 ..< ncomp {
		im.SameLine()
		im.TextUnformatted(comp_names[c])
		im.SameLine()
		if c in off {
			// A lane the row leaves alone.
			im.TextDisabled("-")
			continue
		}
		im.SetNextItemWidth(70)
		_pv_field_undo(doc, clip, im.DragFloat(fmt.ctprintf("##anim_key_v%d", c), &anim.animation_channel_floats(ch)[k][c], 0.01))
	}

	im.SameLine()
	im.BeginDisabled(len(ch.times) <= 1)
	if im.Button(len(_av.sel) > 1 ? fmt.ctprintf("Delete %d Keys", len(_av.sel)) : "Delete Key") {
		_pv_delete_key(doc, clip)
	}
	im.EndDisabled()
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
			ch := &clip.channels[_av.sel_ch]
			if ch.path == .Rotation do _pv_normalize_rot_key(ch, _av.sel_key)
		}
		_pv_edit_commit(doc)
	}
}

// A dragged key stays between its neighbors (and inside the clip), so the
// times array keeps its sort order without reindexing mid-drag.
@(private = "file")
_pv_drag_time_bounds :: proc(ch: ^anim.Animation_Channel, k: int, length: f32) -> (lo, hi: f32) {
	lo = k > 0 ? ch.times[k - 1] : 0
	hi = k < len(ch.times) - 1 ? ch.times[k + 1] : length
	return
}
