package tests

// engine/gizmos: calls record world-space shapes into the context's buffer,
// scopes undo themselves at the end of the block, and lifetimes follow the
// frame or the fixed tick.

import "core:math"
import "core:math/linalg"
import "core:testing"
import "../editor"
import "../editor/menu"
import "../editor/handles"
import "../engine"
import "moonhug:engine/gizmos"

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

	count :: proc(tc: ^TestCtx, kind: engine.Gizmo_Prim_Kind) -> (n: int) {
		for p in _prims(tc) do if p.kind == kind do n += 1
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

	gizmos.set_view(engine.Render_View{cam_pos = {0, 0, 10}}) // straight in front of the +Z face
	{
		gizmos.with_depth_test(false)
		gizmos.solid_box({}, {1, 1, 1})
	}
	gizmos.solid_box({}, {1, 1, 1})
	testing.expect_value(t, len(_prims(tc, depth_tested = false)), 2)
	testing.expect_value(t, len(_prims(tc)), 12)
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
	prev_mode := editor.gizmo_mode
	defer editor.gizmo_mode = prev_mode

	parent := engine.transform_new("Parent")
	child := engine.transform_new("Child", parent)
	other := engine.transform_new("Other")
	editor.sel_scene_only(parent)
	editor.gizmo_mode = .Handles
	editor.gizmo_marks_rebuild()

	p := editor.gizmo_context(parent)
	testing.expect(t, p.state == {.Selected, .Active, .In_Selection}, "the selected object")
	testing.expect(t, p.tool == .Handles, "the scene view's tool")
	testing.expect(t, editor.gizmo_context(child).state == {.In_Selection}, "a child of the selection")
	testing.expect(t, editor.gizmo_context(other).state == {}, "outside the selection")
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
		editor.gizmo_marks_rebuild()
		testing.expectf(t, .Selected in editor.gizmo_context(parent).state, "%s: parent selected", order)
		testing.expectf(t, editor.gizmo_context(child).state >= {.Selected, .In_Selection}, "%s: child selected", order)
		testing.expectf(t, editor.gizmo_context(grandchild).state == {.In_Selection}, "%s: grandchild in the selection", order)
		testing.expectf(t, editor.gizmo_context(other).state == {}, "%s: other outside", order)
	}
	editor.sel_scene_only(child)
	editor.sel_scene_add(parent)
	check(t, parent, child, grandchild, other, "child first")
	editor.sel_scene_only(parent)
	editor.sel_scene_add(child)
	check(t, parent, child, grandchild, other, "parent first")

	// A mark from an earlier rebuild does not count once the selection moved on.
	editor.sel_scene_only(other)
	editor.gizmo_marks_rebuild()
	editor.sel_scene_only(parent)
	editor.gizmo_marks_rebuild()
	testing.expect(t, editor.gizmo_context(other).state == {}, "no stale mark from an earlier selection")

	// Destroy the marked grandchild: a transform created in its slot gets a new
	// generation, so it is not marked until a rebuild says so.
	old := engine.Handle(grandchild)
	engine.transform_destroy(grandchild)
	fresh := engine.transform_new("Fresh")
	testing.expect(t, engine.Handle(fresh).index == old.index, "the new transform reuses the slot (test precondition)")
	testing.expect(t, editor.gizmo_context(fresh).state == {}, "a reused slot does not inherit the mark")
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

	cam_t := engine.transform_new("Camera")
	_, cam_ptr := engine.transform_add_comp(cam_t, .Camera)
	cam := cast(^engine.Camera)cam_ptr
	cam.enabled = true
	editor.sel_scene_only(cam_t)

	menu.show_scene = false
	menu.show_game = true
	editor.game_gizmos = true
	editor.gizmo_pass()
	testing.expect(t, _count(tc, .Editor) > 0, "the selected camera's frustum records for the game view")
	testing.expect_value(t, _count(tc, .Tools), 0)

	gizmos.frame_end()
	editor.game_gizmos = false
	editor.gizmo_pass()
	testing.expect_value(t, _count(tc, .Editor), 0)
}

// --- Scene icons -------------------------------------------------------------------------

@(private = "file")
_no_symbol :: proc() {}

// An icon records as data for its owner, and each view builds it facing its
// own camera: -1..1 spans ICON_PX pixels, upright on that view's screen.
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
	testing.expect(t, ics[0].owner == owner && ics[0].px == handles.ICON_PX, "the owner and the width")

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
	editor.light_gizmos(l, handles.Gizmo_Context{})
	testing.expect_value(t, len(gizmos.icons({.Game, .Editor, .Tools})), 1)

	at, _ := gizmos.helper_project_in(v, {1, 0, 0})
	picked, ok := editor.scene_view_pick(v, at.x + 5, at.y)
	testing.expect(t, ok && picked == lamp, "a click inside the icon picks the light")
	_, ok = editor.scene_view_pick(v, at.x + 40, at.y)
	testing.expect(t, !ok, "outside the icon, nothing")
	band := editor.scene_view_band_query(v, at - 10, at + 10)
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
