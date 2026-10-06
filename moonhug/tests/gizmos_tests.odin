package tests

// host/gizmos: calls record world-space shapes into the context's buffer,
// scopes undo themselves at the end of the block, and lifetimes follow the
// frame or the fixed tick.

import "core:math"
import "core:math/linalg"
import "core:testing"
import "core:time"
import "../editor"
import "../editor/menu"
import "../editor/handles"
import "moonhug:packages/engine"
import gfx "moonhug:host/gfx"
import im "moonhug:external/odin-imgui"
import "moonhug:host/gizmos"
import "moonhug:packages/engine/editor/scene_tools"
import "moonhug:editor/viewport"

@(private = "file")
_prims :: proc(tc: ^TestCtx, lt: engine.Gizmo_Lifetime = .Frame, ch: engine.Gizmo_Channel = .Game, depth_tested := true) -> []engine.Gizmo_Prim {
	return tc.uc.gizmos.batches[lt][ch][depth_tested ? 1 : 0].prims[:]
}

@(private = "file")
_near :: proc(a, b: [3]f32) -> bool {
	return linalg.length(a - b) < 1e-4
}

@(test)
test_gizmo_scopes_restore_at_block_end :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)

	RED :: [4]f32{1, 0, 0, 1}
	{
		gizmos.with_color(RED)
		gizmos.with_matrix(linalg.matrix4_translate_f32({5, 0, 0}))
		gizmos.line({0, 0, 0}, {1, 0, 0})
	}
	gizmos.line({0, 0, 0}, {1, 0, 0})

	p := _prims(tc)
	testing.expect_value(t, len(p), 2)
	if len(p) != 2 do return
	testing.expect(t, p[0].color == RED && _near(p[0].p[0], {5, 0, 0}) && _near(p[0].p[1], {6, 0, 0}), "inside: red, moved by the matrix")
	testing.expect(t, p[1].color == {1, 1, 1, 1} && _near(p[1].p[0], {0, 0, 0}), "after the block: default color, no matrix")
}

// with_matrix composes with the current space, in_local_space replaces it
// with the transform's world matrix.
@(test)
test_gizmo_spaces_compose_and_local_space_replaces :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)

	{
		gizmos.with_matrix(linalg.matrix4_translate_f32({1, 0, 0}))
		gizmos.with_matrix(linalg.matrix4_translate_f32({0, 2, 0}))
		gizmos.line({0, 0, 0}, {0, 0, 1})
	}
	tH := engine.transform_new("Owner")
	tr := engine.pool_get(&tc.world.transforms, engine.Handle(tH))
	tr.position = {10, 0, 0}
	tr.scale = {2, 2, 2}
	{
		gizmos.with_matrix(linalg.matrix4_translate_f32({100, 0, 0}))
		gizmos.in_local_space(tH)
		gizmos.line({0, 0, 0}, {1, 0, 0})
	}

	p := _prims(tc)
	if len(p) != 2 do return
	testing.expect(t, _near(p[0].p[0], {1, 2, 0}), "nested matrices compose")
	testing.expect(t, _near(p[1].p[0], {10, 0, 0}) && _near(p[1].p[1], {12, 0, 0}), "local space is the transform's, not composed")
}

@(test)
test_gizmo_depth_and_channel_pick_the_batch :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)

	{
		gizmos.with_depth_test(false)
		gizmos.line({0, 0, 0}, {1, 0, 0})
	}
	{
		gizmos.with_channel(.Editor)
		gizmos.line({0, 0, 0}, {1, 0, 0})
	}
	testing.expect_value(t, len(_prims(tc, depth_tested = false)), 1)
	testing.expect_value(t, len(_prims(tc, ch = .Editor)), 1)
	testing.expect_value(t, len(_prims(tc)), 0)
}

// Frame shapes go at frame_end. Shapes recorded during a fixed tick stay until
// the next tick starts, and Stop (fixed_reset) drops them.
@(test)
test_gizmo_lifetimes :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	defer engine.fixed_reset()

	gizmos.line({0, 0, 0}, {1, 0, 0})
	gizmos.label({0, 0, 0}, "hello")
	engine.fixed_tick_begin()
	gizmos.line({0, 0, 0}, {0, 1, 0})
	engine.fixed_tick_advance()

	testing.expect_value(t, len(_prims(tc)), 1)
	testing.expect_value(t, len(_prims(tc, lt = .Fixed_Tick)), 1)
	testing.expect_value(t, len(gizmos.labels({.Game})), 1)

	gizmos.frame_end()
	testing.expect_value(t, len(_prims(tc)), 0)
	testing.expect_value(t, len(gizmos.labels({.Game})), 0)
	testing.expect_value(t, len(_prims(tc, lt = .Fixed_Tick)), 1) // a frame with no tick still shows it

	engine.fixed_tick_begin()
	testing.expect_value(t, len(_prims(tc, lt = .Fixed_Tick)), 0)
	gizmos.line({0, 0, 0}, {0, 1, 0})
	engine.fixed_tick_advance()
	engine.fixed_reset()
	testing.expect_value(t, len(_prims(tc, lt = .Fixed_Tick)), 0)
}

@(test)
test_gizmo_shapes_geometry :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)

	// A solid volume's triangles record as faces: they count as triangles.
	count :: proc(tc: ^TestCtx, kind: engine.Gizmo_Prim_Kind) -> (n: int) {
		for p in _prims(tc) do if p.kind == kind || (kind == .Triangle && p.kind == .Face) do n += 1
		return
	}
	check :: proc(t: ^testing.T, tc: ^TestCtx, name: string, lines, triangles: int, loc := #caller_location) {
		testing.expectf(t, count(tc, .Line) == lines && count(tc, .Triangle) == triangles,
			"%s: %d lines and %d triangles, got %d and %d", name, lines, triangles, count(tc, .Line), count(tc, .Triangle), loc = loc)
		gizmos.frame_end()
	}

	gizmos.wire_box({0, 0, 0}, {2, 4, 6})
	for p in _prims(tc) {
		for i in 0 ..< 2 {
			q := p.p[i]
			testing.expect(t, abs(q.x) == 1 && abs(q.y) == 2 && abs(q.z) == 3, "box corners at half size")
		}
	}
	check(t, tc, "wire_box", 12, 0)
	gizmos.solid_box({0, 0, 0}, {1, 1, 1});                          check(t, tc, "solid_box", 0, 12)
	gizmos.wire_circle({0, 0, 0}, {0, 1, 0}, 2, segments = 16)
	for p in _prims(tc) do testing.expect(t, abs(linalg.length(p.p[0]) - 2) < 1e-4 && abs(p.p[0].y) < 1e-5, "circle points at the radius, in the plane")
	check(t, tc, "wire_circle", 16, 0)
	gizmos.solid_circle({0, 0, 0}, {0, 0, 1}, 1, segments = 8);      check(t, tc, "solid_circle", 0, 8)
	gizmos.wire_arc({0, 0, 0}, {0, 0, 1}, {1, 0, 0}, math.PI, 1, segments = 6)
	p := _prims(tc)
	testing.expect(t, len(p) == 6 && _near(p[0].p[0], {1, 0, 0}) && _near(p[5].p[1], {-1, 0, 0}), "arc from `from` through angle")
	check(t, tc, "wire_arc", 6, 0)
	gizmos.solid_arc({0, 0, 0}, {0, 0, 1}, {1, 0, 0}, 1, 1, segments = 5); check(t, tc, "solid_arc", 0, 5)
	gizmos.wire_rect({0, 0, 0}, {2, 2});                              check(t, tc, "wire_rect", 4, 0)
	gizmos.solid_rect({0, 0, 0}, {2, 2});                             check(t, tc, "solid_rect", 0, 2)
	gizmos.wire_triangle({0, 0, 0}, {1, 0, 0}, {0, 1, 0});            check(t, tc, "wire_triangle", 3, 0)
	gizmos.solid_polygon({{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}, {-1, 0.5, 0}}); check(t, tc, "solid_polygon", 0, 3)
	gizmos.wire_sphere({0, 0, 0}, 1, segments = 8);                   check(t, tc, "wire_sphere", 24, 0)
	gizmos.wire_capsule({0, 0, 0}, {0, 2, 0}, 0.5, segments = 8);     check(t, tc, "wire_capsule", 8 + 8 + 4 + 4 * 4, 0)
	gizmos.wire_cylinder({0, 0, 0}, {0, 2, 0}, 0.5, segments = 8);    check(t, tc, "wire_cylinder", 8 + 8 + 4, 0)
	gizmos.wire_cone({0, 0, 0}, {0, 2, 0}, 0.5, segments = 8);        check(t, tc, "wire_cone", 8 + 4, 0)
	gizmos.solid_cone({0, 0, 0}, {0, 2, 0}, 0.5, segments = 8);       check(t, tc, "solid_cone", 0, 8 + 8)
	near := [4][3]f32{{-1, -1, 1}, {1, -1, 1}, {1, 1, 1}, {-1, 1, 1}}
	far := [4][3]f32{{-2, -2, 5}, {2, -2, 5}, {2, 2, 5}, {-2, 2, 5}}
	gizmos.wire_frustum(near, far);                                   check(t, tc, "wire_frustum", 12, 0)
	gizmos.solid_frustum(near, far);                                  check(t, tc, "solid_frustum", 0, 12)
	gizmos.line_arrow({0, 0, 0}, {0, 0, 1});                          check(t, tc, "line_arrow", 5, 0)
	gizmos.line_poly({{0, 0, 0}, {1, 0, 0}, {1, 1, 0}}, closed = true); check(t, tc, "line_poly closed", 3, 0)
	gizmos.line_dashed({0, 0, 0}, {10, 0, 0}, 1);                     check(t, tc, "line_dashed", 5, 0)
	gizmos.line_cross({0, 0, 0}, 1);                                  check(t, tc, "line_cross", 3, 0)
	gizmos.line_axes({0, 0, 0}, 1);                                   check(t, tc, "line_axes", 3, 0)
	gizmos.line_grid({0, 0, 0}, {4, 2}, {4, 2});                      check(t, tc, "line_grid", 5 + 3, 0)
	gizmos.curve_bezier({0, 0, 0}, {0, 1, 0}, {1, 1, 0}, {1, 0, 0}, segments = 10)
	p = _prims(tc)
	testing.expect(t, len(p) == 10 && _near(p[9].p[1], {1, 0, 0}), "bezier ends at p3")
	check(t, tc, "curve_bezier", 10, 0)
}

// A solid volume drawn without depth test keeps only the faces turned to the
// camera: nothing sorts the triangles, so a back face would paint over the
// front. With depth test every face is drawn.
@(test)
test_gizmo_overlay_solids_keep_camera_facing_faces :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)

	{
		gizmos.with_depth_test(false)
		gizmos.solid_box({}, {1, 1, 1})
	}
	gizmos.solid_box({}, {1, 1, 1})
	// Every face records, with no view: each view culls for its own camera.
	testing.expect_value(t, len(_prims(tc, depth_tested = false)), 12)
	testing.expect_value(t, len(_prims(tc)), 12)

	visible :: proc(tc: ^TestCtx, cam: [3]f32) -> (n: int, normal: [3]f32) {
		for p in _prims(tc, depth_tested = false) {
			if _, ok := gizmos.helper_face(engine.Render_View{cam_pos = cam}, p); ok {
				n += 1
				normal = linalg.normalize(linalg.cross(p.p[1] - p.p[0], p.p[2] - p.p[0]))
			}
		}
		return
	}
	front, fn := visible(tc, {0, 0, 10}) // straight in front of the +Z face
	side, sn := visible(tc, {10, 0, 0}) // in front of the +X face
	testing.expect(t, front == 2 && _near(fn, {0, 0, 1}), "the +Z face for a camera on +Z")
	testing.expect(t, side == 2 && _near(sn, {1, 0, 0}), "the +X face for a camera on +X")
}

// What a gizmo or handles hook is told: the selected object is Selected, Active
// and In_Selection, its child only In_Selection (a parent selected counts, the
// way collider wires show for a selected parent), an unrelated object nothing.
// The tool is the scene view's.
@(test)
test_gizmo_context_selection_state :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	defer editor.sel_scene_clear()
	prev_mode := viewport.gizmo_mode
	defer viewport.gizmo_mode = prev_mode

	parent := engine.transform_new("Parent")
	child := engine.transform_new("Child", parent)
	other := engine.transform_new("Other")
	editor.sel_scene_only(parent)
	viewport.gizmo_mode = .Handles
	scene_tools.gizmo_marks_rebuild()

	p := scene_tools.gizmo_context(parent)
	testing.expect(t, p.state == {.Selected, .Active, .In_Selection}, "the selected object")
	testing.expect(t, p.tool == .Handles, "the scene view's tool")
	testing.expect(t, scene_tools.gizmo_context(child).state == {.In_Selection}, "a child of the selection")
	testing.expect(t, scene_tools.gizmo_context(other).state == {}, "outside the selection")
}

// The marks come out the same whichever of a parent and its child is selected
// first (the second root's subtree was already walked by the first), and a
// transform that reuses a marked slot does not inherit the mark.
@(test)
test_gizmo_marks_selection_order_and_slot_reuse :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	defer editor.sel_scene_clear()

	parent := engine.transform_new("Parent")
	child := engine.transform_new("Child", parent)
	grandchild := engine.transform_new("Grandchild", child)
	other := engine.transform_new("Other")

	check :: proc(t: ^testing.T, parent, child, grandchild, other: engine.Transform_Handle, order: string) {
		scene_tools.gizmo_marks_rebuild()
		testing.expectf(t, .Selected in scene_tools.gizmo_context(parent).state, "%s: parent selected", order)
		testing.expectf(t, scene_tools.gizmo_context(child).state >= {.Selected, .In_Selection}, "%s: child selected", order)
		testing.expectf(t, scene_tools.gizmo_context(grandchild).state == {.In_Selection}, "%s: grandchild in the selection", order)
		testing.expectf(t, scene_tools.gizmo_context(other).state == {}, "%s: other outside", order)
	}
	editor.sel_scene_only(child)
	editor.sel_scene_add(parent)
	check(t, parent, child, grandchild, other, "child first")
	editor.sel_scene_only(parent)
	editor.sel_scene_add(child)
	check(t, parent, child, grandchild, other, "parent first")

	// A mark from an earlier rebuild does not count once the selection moved on.
	editor.sel_scene_only(other)
	scene_tools.gizmo_marks_rebuild()
	editor.sel_scene_only(parent)
	scene_tools.gizmo_marks_rebuild()
	testing.expect(t, scene_tools.gizmo_context(other).state == {}, "no stale mark from an earlier selection")

	// Destroy the marked grandchild: a transform created in its slot gets a new
	// generation, so it is not marked until a rebuild says so.
	old := engine.Handle(grandchild)
	engine.transform_destroy(grandchild)
	fresh := engine.transform_new("Fresh")
	testing.expect(t, engine.Handle(fresh).index == old.index, "the new transform reuses the slot (test precondition)")
	testing.expect(t, scene_tools.gizmo_context(fresh).state == {}, "a reused slot does not inherit the mark")
}

// --- Gizmo pass ------------------------------------------------------------------------

@(private = "file")
_count :: proc(tc: ^TestCtx, ch: engine.Gizmo_Channel) -> int {
	return len(_prims(tc, ch = ch, depth_tested = true)) + len(_prims(tc, ch = ch, depth_tested = false))
}

// The pass records the gizmo hooks while only the game view shows gizmos, so
// the game view has them with the scene view closed. The scene-only tools
// (outline, handles) need the scene view on screen, and nothing records while
// neither view shows gizmos.
@(test)
test_gizmo_pass_records_for_the_game_view_alone :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	defer editor.sel_scene_clear()
	prev_scene, prev_game, prev_toggle := menu.show_scene, menu.show_game, editor.game_gizmos
	defer {
		menu.show_scene = prev_scene
		menu.show_game = prev_game
		editor.game_gizmos = prev_toggle
	}

	prev_rt := editor.game_rt
	defer editor.game_rt = prev_rt
	rt := gfx.Render_Target{width = 800, height = 600} // the game view's size, no GPU needed
	editor.game_rt = &rt

	cam_t := engine.transform_new("Camera")
	_, cam_ptr := engine.transform_add_comp(cam_t, .Camera)
	cam := cast(^engine.Camera)cam_ptr
	cam.enabled = true
	editor.sel_scene_only(cam_t)

	menu.show_scene = false
	menu.show_game = true
	editor.game_gizmos = true
	editor.gizmo_pass()
	testing.expect(t, _count(tc, .Editor_Game) > 0, "the selected camera's frustum records for the game view")
	testing.expect_value(t, _count(tc, .Editor), 0)
	testing.expect_value(t, _count(tc, .Tools), 0)

	gizmos.frame_end()
	editor.game_gizmos = false
	editor.gizmo_pass()
	testing.expect_value(t, _count(tc, .Editor_Game), 0)
}

// --- Scene icons -------------------------------------------------------------------------

@(private = "file")
_no_symbol :: proc() {}

// An icon records as data for its owner, and each view builds it facing its
// own camera: -1..1 spans the icon size in pixels, upright on that view's screen.
@(test)
test_icon_faces_the_view_that_draws_it :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	gizmos.set_view(handles_test_view())

	owner := engine.transform_new("Lamp")
	handles.icon({1, 0, 0}, owner, _no_symbol)
	ics := gizmos.icons({.Game, .Editor, .Tools})
	testing.expect_value(t, len(ics), 1)
	testing.expect(t, ics[0].owner == owner && ics[0].px == handles.icon_px, "the owner and the width")

	// The scene camera and a game camera somewhere else.
	for v in ([2]engine.Render_View{handles_test_view(), handles_test_view({6, 3, 4})}) {
		m := gizmos.helper_icon_space(v, {1, 0, 0}, 28)
		at :: proc(m: matrix[4, 4]f32, p: [3]f32) -> [3]f32 {
			w := m * [4]f32{p.x, p.y, p.z, 1}
			return w.xyz
		}
		l, _ := gizmos.helper_project_in(v, at(m, {-1, 0, 0}))
		r, _ := gizmos.helper_project_in(v, at(m, {1, 0, 0}))
		c, _ := gizmos.helper_project_in(v, at(m, {0, 0, 0}))
		u, _ := gizmos.helper_project_in(v, at(m, {0, 1, 0}))
		testing.expectf(t, abs(linalg.length(r - l) - 28) < 0.5, "-1..1 spans 28 pixels, got %v", linalg.length(r - l))
		testing.expectf(t, abs(u.x - c.x) < 0.01 && u.y < c.y, "+Y points up on this view's screen: %v %v", c, u)
	}

	// An owner inactive in the hierarchy gets no icon.
	engine.pool_get(&tc.world.transforms, engine.Handle(owner)).is_active = false
	handles.icon({1, 0, 0}, owner, _no_symbol)
	testing.expect_value(t, len(gizmos.icons({.Game, .Editor, .Tools})), 1)
	gizmos.frame_end()
}

// A click on an icon selects its owner, and box select takes it. Every light
// draws one, selected or not.
@(test)
test_icon_picking :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	v := handles_test_view()
	gizmos.set_view(v)

	lamp := engine.transform_new("Lamp")
	engine.transform_set_world_position(lamp, {1, 0, 0})
	_, raw := engine.transform_add_comp(lamp, .Light)
	l := cast(^engine.Light)raw
	l.enabled = true
	scene_tools.light_gizmos(l, handles.Gizmo_Context{})
	testing.expect_value(t, len(gizmos.icons({.Game, .Editor, .Tools})), 1)

	at, _ := gizmos.helper_project_in(v, {1, 0, 0})
	picked, ok := scene_tools.scene_view_pick(v, at.x + 5, at.y)
	testing.expect(t, ok && picked == lamp, "a click inside the icon picks the light")
	_, ok = scene_tools.scene_view_pick(v, at.x + 40, at.y)
	testing.expect(t, !ok, "outside the icon, nothing")
	band := scene_tools.scene_view_band_query(v, at - 10, at + 10)
	testing.expect(t, len(band) == 1 && band[0] == lamp, "box select takes it")
	gizmos.frame_end()
}

// A glyph icon's pixels: the Material Symbols glyph, white, coverage in alpha,
// centered in its square with the font's padding around it. A codepoint the
// font does not have reports ok=false.
@(test)
test_icon_glyph_bitmap :: proc(t: ^testing.T) {
	handles.icon_font_set(editor.MATERIAL_FONT_DATA)
	PX :: 64
	rgba, ok := handles.glyph_bitmap('\ue80f', PX, context.temp_allocator) // snowing
	testing.expect(t, ok && len(rgba) == PX * PX * 4, "the glyph rasterizes")

	covered := 0
	sum: [2]f32
	total: f32
	for y in 0 ..< PX {
		for x in 0 ..< PX {
			a := f32(rgba[(y * PX + x) * 4 + 3])
			if a > 0 do covered += 1
			sum += {f32(x), f32(y)} * a
			total += a
		}
	}
	testing.expect(t, covered > PX * PX / 20, "a visible share of the square is covered")
	testing.expect_value(t, rgba[3], 0) // the top-left corner is padding
	testing.expect(t, rgba[0] == 255 && rgba[1] == 255 && rgba[2] == 255, "white, tinted by the icon color")
	c := sum / total
	testing.expectf(t, abs(c.x - PX / 2) < 6 && abs(c.y - PX / 2) < 6, "about centered, got %v", c)

	_, ok = handles.glyph_bitmap(0x10FFFF, PX, context.temp_allocator)
	testing.expect(t, !ok, "not in the font")
}

// Each kind of icon image records as itself.
@(test)
test_icon_kinds_record :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	gizmos.set_view(handles_test_view())

	owner := engine.transform_new("Thing")
	guid := engine.Asset_GUID{9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9}
	handles.icon({0, 0, 0}, owner, _no_symbol)
	handles.icon({0, 0, 0}, owner, '\ue90f')
	handles.icon({0, 0, 0}, owner, guid)
	ics := gizmos.icons({.Game, .Editor, .Tools})
	testing.expect_value(t, len(ics), 3)
	_, is_symbol := ics[0].image.(engine.Gizmo_Symbol)
	glyph, is_glyph := ics[1].image.(rune)
	tex, is_tex := ics[2].image.(engine.Asset_GUID)
	testing.expect(t, is_symbol, "a symbol")
	testing.expect(t, is_glyph && glyph == '\ue90f', "a glyph")
	testing.expect(t, is_tex && tex == guid && ics[2].color == [4]f32{1, 1, 1, 1}, "a texture, white by default")
	gizmos.frame_end()
}

// --- Gizmo settings -------------------------------------------------------------------------

// The dispatcher applies a type's gizmo settings around its hook: a hidden
// gizmo records no shapes but keeps the icon, a hidden icon drops the icon.
@(test)
test_gizmo_settings_hide_per_type :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	defer editor.sel_scene_clear()
	prev_scene, prev_game, prev_toggle := menu.show_scene, menu.show_game, editor.game_gizmos
	defer {
		menu.show_scene = prev_scene
		menu.show_game = prev_game
		editor.game_gizmos = prev_toggle
		gizmos.gizmo_type_set("Light", .Icon, true)
		gizmos.gizmo_type_set("Light", .Gizmo, true)
	}
	menu.show_scene = false
	menu.show_game = true
	editor.game_gizmos = true
	prev_rt := editor.game_rt
	defer editor.game_rt = prev_rt
	rt := gfx.Render_Target{width = 800, height = 600}
	editor.game_rt = &rt
	cam_t := engine.transform_new("Camera")
	engine.transform_set_world_position(cam_t, {0, 0, 10})
	_, cam_raw := engine.transform_add_comp(cam_t, .Camera)
	(cast(^engine.Camera)cam_raw).enabled = true

	lamp := engine.transform_new("Lamp")
	_, raw := engine.transform_add_comp(lamp, .Light)
	l := cast(^engine.Light)raw
	l.enabled = true
	l.type = .Point
	editor.sel_scene_only(lamp)

	pass :: proc(tc: ^TestCtx, lamp: engine.Transform_Handle) -> (shapes, icons: int) {
		gizmos.frame_end()
		editor.gizmo_pass()
		for ic in gizmos.icons({.Editor_Game}) do if ic.owner == lamp do icons += 1
		return _count(tc, .Editor_Game), icons
	}
	shapes, icons := pass(tc, lamp)
	testing.expect(t, shapes > 0 && icons == 1, "both by default")

	gizmos.gizmo_type_set("Light", .Gizmo, false)
	shapes, icons = pass(tc, lamp)
	testing.expect(t, shapes == 0 && icons == 1, "the gizmo hidden, the icon stays")

	gizmos.gizmo_type_set("Light", .Icon, false)
	shapes, icons = pass(tc, lamp)
	testing.expect(t, shapes == 0 && icons == 0, "both hidden")
	testing.expect(t, gizmos.gizmo_type_shown("Camera") == {.Icon, .Gizmo}, "other types keep theirs")
	gizmos.frame_end()
}

// The scene view's Gizmos toggle: off, it draws no gizmos or icons and picks
// no icon, and keeps gameplay shapes and tools.
@(test)
test_scene_gizmos_toggle :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	defer gizmos.scene_gizmos = true
	v := handles_test_view()
	gizmos.set_view(v)

	lamp := engine.transform_new("Lamp")
	_, raw := engine.transform_add_comp(lamp, .Light)
	l := cast(^engine.Light)raw
	l.enabled = true
	{
		gizmos.with_channel(.Editor)
		scene_tools.light_gizmos(l, handles.Gizmo_Context{})
	}
	at, _ := gizmos.helper_project_in(v, {0, 0, 0})
	_, ok := scene_tools.scene_view_pick(v, at.x, at.y)
	testing.expect(t, ok, "the icon picks with gizmos on")

	gizmos.scene_gizmos = false
	testing.expect(t, gizmos.scene_gizmo_channels() == {.Game, .Tools}, "no .Editor channel")
	_, ok = scene_tools.scene_view_pick(v, at.x, at.y)
	testing.expect(t, !ok, "a hidden icon does not pick")
	gizmos.frame_end()
}

@(test)
test_gizmo_type_labels :: proc(t: ^testing.T) {
	testing.expect_value(t, gizmos.gizmo_type_label("BoxCollider2D"), "Box Collider 2D")
	testing.expect_value(t, gizmos.gizmo_type_label("AudioSource"), "Audio Source")
	testing.expect_value(t, gizmos.gizmo_type_label("Camera"), "Camera")
}

// --- Lifetimes beyond a frame -----------------------------------------------------------------

@(private = "file")
_group_prims :: proc(tc: ^TestCtx) -> int {
	n := 0
	for g in tc.uc.gizmos.groups {
		for per_channel in g.batches {
			for b in per_channel do n += len(b.prims)
		}
	}
	return n
}

@(test)
test_gizmo_duration_on_the_real_clock :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)

	{
		gizmos.with_duration(0.05, .Real)
		gizmos.line({0, 0, 0}, {1, 0, 0})
	}
	gizmos.line({0, 0, 0}, {0, 1, 0}) // a frame's
	gizmos.frame_end()
	testing.expect_value(t, _group_prims(tc), 1)
	testing.expect_value(t, len(_prims(tc)), 0)
	time.sleep(70 * time.Millisecond)
	gizmos.frame_end()
	testing.expect_value(t, len(tc.uc.gizmos.groups), 0)
}

// The game clock is the simulation's fixed ticks: it waits while no tick
// runs, and Stop drops what it timed.
@(test)
test_gizmo_duration_on_the_game_clock :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	engine.fixed_reset()
	defer engine.fixed_reset()

	{
		gizmos.with_duration(0.1)
		gizmos.line({0, 0, 0}, {1, 0, 0})
	}
	for _ in 0 ..< 3 do engine.fixed_tick_advance() // 0.05 s at 60 Hz
	gizmos.frame_end()
	testing.expect_value(t, _group_prims(tc), 1)
	for _ in 0 ..< 4 do engine.fixed_tick_advance() // 0.117 s
	gizmos.frame_end()
	testing.expect_value(t, len(tc.uc.gizmos.groups), 0)

	{
		gizmos.with_duration(10)
		gizmos.line({0, 0, 0}, {1, 0, 0})
	}
	engine.fixed_reset()
	testing.expect_value(t, len(tc.uc.gizmos.groups), 0)
}

// Shapes under a key stay across frames, add up within a frame, are replaced
// when the key records in a later frame, and go with clear_key.
@(test)
test_gizmo_key :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)

	draw :: proc(n: int) {
		gizmos.with_key(7)
		for _ in 0 ..< n do gizmos.line({0, 0, 0}, {1, 0, 0})
	}
	draw(1)
	gizmos.frame_end()
	testing.expect_value(t, _group_prims(tc), 1)
	draw(1)
	draw(1)
	testing.expect_value(t, _group_prims(tc), 2)
	gizmos.frame_end()
	draw(1)
	testing.expect_value(t, _group_prims(tc), 1)
	{
		gizmos.with_key(7)
		gizmos.label({0, 0, 0}, "kept")
	}
	testing.expect_value(t, len(gizmos.labels({.Game})), 1)
	gizmos.clear_key(7)
	testing.expect_value(t, len(tc.uc.gizmos.groups), 0)
}

// --- Gizmo pass: the scene view branch, game view labels ------------------------------------

// With the scene view on screen (it rendered last frame), the pass records
// the selection outline and the transform gizmo into the scene-only .Tools
// channel, and publishes the handles frame with the scene camera.
@(test)
test_gizmo_pass_records_tools_for_the_scene_view :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	ictx := im.CreateContext()
	defer im.DestroyContext(ictx)
	defer editor.sel_scene_clear()

	prev_scene, prev_game := menu.show_scene, menu.show_game
	prev_frame, prev_rendered, prev_size := gfx.frame_index, editor._scene_rendered_frame, editor._scene_view_size
	prev_cam, prev_target, prev_mode := editor.scene_cam_pos, editor.scene_cam_target, viewport.gizmo_mode
	defer {
		menu.show_scene = prev_scene
		menu.show_game = prev_game
		gfx.frame_index = prev_frame
		editor._scene_rendered_frame = prev_rendered
		editor._scene_view_size = prev_size
		editor.scene_cam_pos = prev_cam
		editor.scene_cam_target = prev_target
		viewport.gizmo_mode = prev_mode
	}
	menu.show_scene = true
	menu.show_game = false
	editor.scene_cam_pos = {0, 0, 10}
	editor.scene_cam_target = {0, 0, 0}
	viewport.gizmo_mode = .Translate
	gfx.frame_index += 1
	editor._scene_rendered_frame = gfx.frame_index - 1
	editor._scene_view_size = {800, 600}

	obj := engine.transform_new("Obj")
	editor.sel_scene_only(obj)
	editor.gizmo_pass()
	testing.expect(t, _count(tc, .Tools) > 0, "the outline and the transform gizmo record into .Tools")
	f := handles.frame()
	testing.expect(t, f.valid && f.view.width == 800 && f.view.height == 600, "the handles frame is the scene view's")
	testing.expectf(t, linalg.length(f.view.cam_pos - [3]f32{0, 0, 10}) < 1e-3, "with the scene camera, got %v", f.view.cam_pos)
	gizmos.frame_end()
}

// A label lands on the game image where the camera sees it, scaled from the
// render target's pixels onto the image (zoom, letterbox), plus its offset.
// Off the image, none.
@(test)
test_game_view_label_position :: proc(t: ^testing.T) {
	v := handles_test_view() // 800x600, the origin at its center
	l := engine.Gizmo_Label{pos = {0, 0, 0}, offset_px = {3, -2}}
	p, ok := editor.game_label_pos(v, {5, 5}, {400, 300}, l)
	testing.expectf(t, ok && linalg.length(p - [2]f32{208, 153}) < 0.01, "center of a half-size image, got %v", p)
	l.pos = {100, 0, 0} // far to the right, off the image
	_, ok = editor.game_label_pos(v, {5, 5}, {400, 300}, l)
	testing.expect(t, !ok, "off the image")
}

// With both views showing gizmos, the @(on_draw_gizmos) procs record once per
// camera: a pixel-sized gizmo (a directional light's rays) is built for each
// view's own camera, three times bigger for a game camera three times farther.
@(test)
test_gizmos_record_per_camera :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	ictx := im.CreateContext()
	defer im.DestroyContext(ictx)
	defer editor.sel_scene_clear()

	prev_scene, prev_game, prev_toggle := menu.show_scene, menu.show_game, editor.game_gizmos
	prev_frame, prev_rendered, prev_size := gfx.frame_index, editor._scene_rendered_frame, editor._scene_view_size
	prev_cam, prev_target, prev_rt := editor.scene_cam_pos, editor.scene_cam_target, editor.game_rt
	defer {
		menu.show_scene = prev_scene
		menu.show_game = prev_game
		editor.game_gizmos = prev_toggle
		gfx.frame_index = prev_frame
		editor._scene_rendered_frame = prev_rendered
		editor._scene_view_size = prev_size
		editor.scene_cam_pos = prev_cam
		editor.scene_cam_target = prev_target
		editor.game_rt = prev_rt
	}
	// The scene view on screen, its camera 10 away.
	menu.show_scene = true
	editor.scene_cam_pos = {0, 0, 10}
	editor.scene_cam_target = {0, 0, 0}
	gfx.frame_index += 1
	editor._scene_rendered_frame = gfx.frame_index - 1
	editor._scene_view_size = {800, 600}
	// The game view showing gizmos, its camera 30 away.
	menu.show_game = true
	editor.game_gizmos = true
	rt := gfx.Render_Target{width = 800, height = 600}
	editor.game_rt = &rt
	cam_t := engine.transform_new("Camera")
	engine.transform_set_world_position(cam_t, {0, 0, 30})
	_, cam_raw := engine.transform_add_comp(cam_t, .Camera)
	(cast(^engine.Camera)cam_raw).enabled = true

	sun := engine.transform_new("Sun")
	_, raw := engine.transform_add_comp(sun, .Light)
	l := cast(^engine.Light)raw
	l.enabled = true
	l.type = .Directional
	editor.sel_scene_only(sun)

	editor.gizmo_pass()
	extent :: proc(tc: ^TestCtx, ch: engine.Gizmo_Channel) -> (r: f32) {
		for depth in ([2]bool{true, false}) {
			for p in _prims(tc, ch = ch, depth_tested = depth) do r = max(r, linalg.length(p.p[0].xy), linalg.length(p.p[1].xy))
		}
		return
	}
	scene, game := extent(tc, .Editor), extent(tc, .Editor_Game)
	testing.expect(t, scene > 0 && game > 0, "both views recorded the rays")
	testing.expectf(t, game > scene * 2, "each built for its own camera: %v in the scene view, %v in the game view", scene, game)
	gizmos.frame_end()
}
