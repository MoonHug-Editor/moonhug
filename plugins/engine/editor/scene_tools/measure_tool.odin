package scene_tools

// The Measure tool (M, docs/core/Handles.md): a drag in the Scene window
// measures from where it starts to where it ends, and the measurement stays
// until the next drag, a click, or another tool.
//
// - An end lands where the pointer meets an object (scene_window_surface_point),
//   on a UI canvas, or on the grid plane over empty space. While snapping is
//   on, an end off a canvas snaps to the move step.
// - Both ends on one canvas: the distance is in the canvas's units, which are
//   its pixels, and the ends snap to whole pixels. Else it is in world units.
//   An overlay canvas counts in an orthographic view (2D) only: in 3D it is a
//   rectangle of hundreds of units at the origin that every measurement near
//   it would land on. A canvas in the world or before a camera always counts.
// - It shows the line between the ends, its legs along each axis in the
//   axis colors, the distance at the middle and each axis's part under it.
// - While the tool is on, a left click or drag never selects
//   (scene_tools_consume_mouse).

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strings"
import "moonhug:editor/handles"
import "moonhug:editor/viewport"
import "moonhug:libs/gizmos"
import "moonhug:packages/engine"

// What the Measure tool measured: its ends in world space, and the canvas
// both lie on, with the ends in that canvas's units ({} for none).
Measurement :: struct {
	a, b:     [3]f32,
	canvas:   engine.Transform_Handle,
	ca, cb:   [2]f32,
}

// The measurement shown now, ok false with none.
measure_result :: proc() -> (m: Measurement, ok: bool) {
	return _measure.m, _measure.has
}

// The distance, in canvas pixels when both ends are on one canvas, and its
// part along each axis: x and y, and z off a canvas.
measure_distance :: proc(m: Measurement) -> (distance: f32, parts: [3]f32, pixels: bool) {
	if m.canvas != {} {
		d := m.cb - m.ca
		return linalg.length(d), {abs(d.x), abs(d.y), 0}, true
	}
	d := m.b - m.a
	return linalg.length(d), {abs(d.x), abs(d.y), abs(d.z)}, false
}

@(private = "file")
_measure: struct {
	m:        Measurement,
	has:      bool,
	dragging: bool,
	press_px: [2]f32,
	// The canvas the drag started on: the measurement is on it while the
	// end is too, also after the end left it and came back.
	start_on: engine.Transform_Handle,
}

@(private = "file")
_End :: struct {
	world:  [3]f32,
	canvas: engine.Transform_Handle,
	local:  [2]f32,
}

// Pointer travel, in pixels, under which a press and release is a click:
// it clears the measurement.
@(private = "file")
_CLICK_PX :: f32(3)

@(private = "file")
_COLOR :: [4]f32{1, 0.85, 0.2, 1}

// The tool's frame, from scene_tools_frame in the handles frame.
measure_tool_frame :: proc() {
	if viewport.gizmo_mode != .Measure {
		_measure = {}
		return
	}
	f := handles.frame()
	if !f.valid do return
	input := f.input
	if input.clicked && input.hovered && !input.alt {
		if p, ok := _measure_end(f); ok {
			_measure.m = {a = p.world, b = p.world, canvas = p.canvas, ca = p.local, cb = p.local}
			_measure.start_on = p.canvas
			_measure.has = true
			_measure.dragging = true
			_measure.press_px = input.mouse
		}
	}
	if _measure.dragging {
		if p, ok := _measure_end(f); ok {
			_measure.m.b = p.world
			_measure.m.cb = p.local
			// Off the canvas the start lies on, both ends count in world units.
			_measure.m.canvas = _measure.start_on if p.canvas == _measure.start_on else {}
		}
		if !input.down {
			_measure.dragging = false
			if linalg.length(input.mouse - _measure.press_px) < _CLICK_PX do _measure = {}
		}
	}
	if _measure.has do _measure_draw(f.view)
}

// Where an end lands under the pointer: the nearest of an object's surface
// and a canvas, else the grid plane. Depth counts from the camera along the
// ray: an orthographic view's ray starts mid-depth, not at the camera.
@(private = "file")
_measure_end :: proc(f: handles.Frame) -> (_End, bool) {
	ray := f.ray
	depth :: proc(f: handles.Frame, p: [3]f32) -> f32 { return linalg.dot(p - f.view.cam_pos, f.ray.direction) }
	end: _End
	best := max(f32)
	found := false
	if hit, ok := scene_window_surface_point(f.view, f.input.mouse.x, f.input.mouse.y); ok {
		end.world = hit
		best = depth(f, hit)
		found = true
	}
	w := engine.ctx_world()
	if pool := engine.canvases(w); pool != nil {
		it := engine.pool_iterator(pool)
		for cv, _ in engine.pool_next(&it) {
			if !cv.enabled || !engine.transform_active_in_hierarchy(cv.owner) do continue
			root, xform, in_world := engine.canvas_placement(cv.owner, engine.canvas_game_viewport())
			if !in_world && !_orthographic(f.view) do continue
			origin := (xform * [4]f32{0, 0, 0, 1}).xyz
			normal := linalg.normalize0((xform * [4]f32{0, 0, 1, 0}).xyz)
			hit, ok := handles.ray_plane(ray, origin, normal)
			if !ok do continue
			t := depth(f, hit)
			// A surface on the canvas (a UI graphic) is the canvas too.
			if t < 0 || t > best + 0.001 * max(best, 1) do continue
			local := (linalg.inverse(xform) * [4]f32{hit.x, hit.y, hit.z, 1}).xy
			if local.x < root.pos.x || local.y < root.pos.y || local.x > root.pos.x + root.size.x || local.y > root.pos.y + root.size.y do continue
			local = {math.round(local.x), math.round(local.y)}
			end = {world = (xform * [4]f32{local.x, local.y, 0, 1}).xyz, canvas = cv.owner, local = local}
			best = t
			found = true
		}
	}
	if !found do end.world = f.input.ground
	if end.canvas == {} do end.world = {handles.snap(end.world.x), handles.snap(end.world.y), handles.snap(end.world.z)}
	return end, true
}

// An orthographic projection keeps w at 1: its last row is 0 0 0 1.
@(private = "file")
_orthographic :: proc(view: engine.Render_View) -> bool {
	return abs(view.proj[3, 3] - 1) < 1e-4
}

@(private = "file")
_measure_draw :: proc(view: engine.Render_View) {
	m := _measure.m
	gizmos.in_world_space()
	gizmos.with_depth_test(false)

	// The legs, one per axis, in the axis colors: on a canvas along its axes.
	corners: [4][3]f32
	if m.canvas != {} {
		_, xform, _ := engine.canvas_placement(m.canvas, engine.canvas_game_viewport())
		at := proc(xform: matrix[4, 4]f32, p: [2]f32) -> [3]f32 { return (xform * [4]f32{p.x, p.y, 0, 1}).xyz }
		corners = {at(xform, m.ca), at(xform, {m.cb.x, m.ca.y}), at(xform, m.cb), at(xform, m.cb)}
	} else {
		corners = {m.a, {m.b.x, m.a.y, m.a.z}, {m.b.x, m.b.y, m.a.z}, m.b}
	}
	axes := handles.COLOR_AXES
	for i in 0 ..< 3 {
		if linalg.length(corners[i + 1] - corners[i]) < 1e-5 do continue
		c := axes[i]
		gizmos.with_color({c.r, c.g, c.b, 0.6})
		gizmos.line(corners[i], corners[i + 1])
	}

	gizmos.with_color(_COLOR)
	gizmos.line(m.a, m.b)
	back := linalg.normalize0(view.cam_pos - m.a)
	handles.dot_outlined(m.a, back, handles.world_per_pixels(m.a, 4), _COLOR)
	handles.dot_outlined(m.b, linalg.normalize0(view.cam_pos - m.b), handles.world_per_pixels(m.b, 4), _COLOR)

	distance, parts, pixels := measure_distance(m)
	unit := " px" if pixels else ""
	mid := (m.a + m.b) * 0.5
	gizmos.label(mid, fmt.tprintf("%s%s", _measure_number(distance), unit), align = {0.5, 1}, offset_px = {0, -6})
	// Each axis's part, when more than one axis has one.
	names := [3]string{"x", "y", "z"}
	b := strings.builder_make(context.temp_allocator)
	moving := 0
	for p in parts do if p > 1e-5 do moving += 1
	if moving > 1 {
		for p, i in parts {
			if p <= 1e-5 do continue
			if strings.builder_len(b) > 0 do strings.write_string(&b, "   ")
			fmt.sbprintf(&b, "%s %s", names[i], _measure_number(p))
		}
		gizmos.with_color({0.85, 0.85, 0.85, 1})
		gizmos.label(mid, strings.to_string(b), align = {0.5, 0}, offset_px = {0, 6})
	}
}

// A distance with at most three decimals and no trailing zeros: 2.5, 128.
@(private = "file")
_measure_number :: proc(v: f32) -> string {
	s := fmt.tprintf("%.3f", v)
	s = strings.trim_right(s, "0")
	return strings.trim_suffix(s, ".")
}
