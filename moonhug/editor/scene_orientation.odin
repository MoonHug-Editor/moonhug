package editor

// The Orientation overlay (Unity's scene gizmo, an overlay since Unity 2021):
// the six world axes projected through the scene camera. Click an axis to
// look along it (camera on that side, looking at the anchor), click the
// center or the label to switch between perspective and orthographic.
// Dockable and draggable like every scene overlay; docks top-right by
// default. Draws nothing in 2D mode, where the view direction is fixed, so
// the overlay chrome vanishes with it.

import "core:math"
import "core:math/linalg"
import im "moonhug:external/odin-imgui"

_ORIENT_RADIUS :: f32(36) // widget radius, px
_ORIENT_TIP :: f32(7)     // positive-axis tip radius
_ORIENT_TIP_NEG :: f32(5) // negative-axis ring radius
_ORIENT_HIT :: f32(10)    // click radius around a tip

// Unity's axis colors.
_ORIENT_X :: [4]f32{0.86, 0.24, 0.11, 1}
_ORIENT_Y :: [4]f32{0.60, 0.95, 0.28, 1}
_ORIENT_Z :: [4]f32{0.23, 0.48, 0.97, 1}

_Orient_Axis :: struct {
	axis:  [3]f32,
	label: cstring,
	color: [4]f32,
}

_ORIENT_AXES := [6]_Orient_Axis{
	{{1, 0, 0}, "X", _ORIENT_X}, {{-1, 0, 0}, "", _ORIENT_X},
	{{0, 1, 0}, "Y", _ORIENT_Y}, {{0, -1, 0}, "", _ORIENT_Y},
	{{0, 0, 1}, "Z", _ORIENT_Z}, {{0, 0, -1}, "", _ORIENT_Z},
}

// Look along -axis from the +axis side, keeping the anchor and distance:
// clicking X gives the view from the right, Y the view from above. A vertical
// axis keeps the current yaw, which is what makes the top view predictable.
scene_view_from_axis :: proc(axis: [3]f32) {
	fwd := -axis
	if abs(fwd.y) < 0.999 {
		scene_cam_yaw = math.atan2(fwd.z, fwd.x)
	}
	scene_cam_pitch = clamp(math.asin(fwd.y), -PITCH_LIMIT, PITCH_LIMIT)
	f, _, _ := _scene_cam_basis()
	scene_cam_pos = scene_cam_target - f * scene_cam_dist
	update_scene_camera()
}

@(scene_overlay={id="Orientation", order=0})
draw_orientation_overlay :: proc(vertical: bool) {
	if scene_2d_mode do return // nothing drawn: the overlay hides itself

	// Reserve the widget's box as one imgui item; everything draws into it.
	label: cstring = scene_cam_ortho ? "Iso" : "Persp"
	label_size := im.CalcTextSize(label)
	im.Dummy({2 * _ORIENT_RADIUS, 2 * _ORIENT_RADIUS + 4 + label_size.y})
	box_min := im.GetItemRectMin()
	center := box_min + {_ORIENT_RADIUS, _ORIENT_RADIUS}
	dl := im.GetWindowDrawList()
	fwd, right, up := _scene_cam_basis()

	// Project the six endpoints; draw farthest first so near tips cover far.
	pts: [6]im.Vec2
	depth: [6]f32
	order: [6]int
	reach := _ORIENT_RADIUS - _ORIENT_TIP
	for a, i in _ORIENT_AXES {
		sx := linalg.dot(a.axis, right)
		sy := linalg.dot(a.axis, up)
		pts[i] = {center.x + sx * reach, center.y - sy * reach}
		depth[i] = linalg.dot(a.axis, fwd) // > 0 points away from the viewer
		order[i] = i
	}
	for i in 1 ..< 6 {
		j := i
		for j > 0 && depth[order[j]] > depth[order[j - 1]] {
			order[j], order[j - 1] = order[j - 1], order[j]
			j -= 1
		}
	}

	label_pos := im.Vec2{center.x - label_size.x * 0.5, center.y + _ORIENT_RADIUS + 4}
	mouse := im.GetMousePos()
	over_ball := linalg.length(mouse - center) <= _ORIENT_RADIUS
	over_label := im.IsMouseHoveringRect({box_min.x, label_pos.y}, {box_min.x + 2 * _ORIENT_RADIUS, label_pos.y + label_size.y})

	// Nearest tip under the pointer, near-to-far so an aligned pair picks the
	// front one.
	hot := -1
	if over_ball {
		best := _ORIENT_HIT * _ORIENT_HIT
		for oi := 5; oi >= 0; oi -= 1 {
			i := order[oi]
			d := mouse - pts[i]
			if dd := d.x * d.x + d.y * d.y; dd < best {
				best = dd
				hot = i
			}
		}
	}
	over_center := over_ball && hot < 0 && linalg.length(mouse - center) <= _ORIENT_TIP + 2

	hot_col := im.GetColorU32ImVec4({1, 1, 0.85, 1})
	for oi in 0 ..< 6 {
		i := order[oi]
		a := _ORIENT_AXES[i]
		// Axes pointing away fade a little, like Unity's back cones.
		fade := f32(1) if depth[i] <= 0 else 0.6
		col := im.GetColorU32ImVec4({a.color.r, a.color.g, a.color.b, fade})
		if a.label != "" {
			im.DrawList_AddLine(dl, center, pts[i], col, 2)
			im.DrawList_AddCircleFilled(dl, pts[i], _ORIENT_TIP, hot == i ? hot_col : col)
			ts := im.CalcTextSize(a.label)
			im.DrawList_AddText(dl, pts[i] - ts * 0.5, im.GetColorU32ImVec4({0, 0, 0, 0.9}), a.label)
		} else if hot == i {
			im.DrawList_AddCircleFilled(dl, pts[i], _ORIENT_TIP_NEG, hot_col)
		} else {
			im.DrawList_AddCircle(dl, pts[i], _ORIENT_TIP_NEG, col, 0, 1.5)
		}
	}
	// The center: the projection toggle (Unity's cube), and the label. The
	// overlay has no panel, so both read against the scene itself: light on a
	// dark shadow, whatever the theme.
	light := im.GetColorU32ImVec4({0.9, 0.9, 0.9, 1})
	shadow := im.GetColorU32ImVec4({0, 0, 0, 0.8})
	im.DrawList_AddCircleFilled(dl, center, _ORIENT_TIP - 1, over_center ? hot_col : light)
	im.DrawList_AddText(dl, label_pos + {1, 1}, shadow, label)
	im.DrawList_AddText(dl, label_pos, over_label ? hot_col : light, label)

	if im.IsMouseClicked(.Left) {
		if hot >= 0 {
			scene_view_from_axis(_ORIENT_AXES[hot].axis)
		} else if over_center || over_label {
			scene_cam_ortho = !scene_cam_ortho
		}
	}
	if hot >= 0 {
		a := _ORIENT_AXES[hot]
		im.SetTooltip(a.axis.y > 0.5 ? "Top" : a.axis.y < -0.5 ? "Bottom" : a.axis.x > 0.5 ? "Right" : a.axis.x < -0.5 ? "Left" : a.axis.z > 0.5 ? "Front" : "Back")
	} else if over_center || over_label {
		im.SetTooltip(scene_cam_ortho ? "Orthographic — click for perspective" : "Perspective — click for orthographic")
	}
}
