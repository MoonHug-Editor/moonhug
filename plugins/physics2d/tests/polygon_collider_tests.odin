package physics2d_tests

// PolygonCollider2D and EdgeCollider2D: the convex partition keeps a
// concave outline's shape and area, a ball lands in an L's inner corner
// instead of on its hull, a 12-gon splits into pieces of at most 8, a
// crossing path is refused, and a V-shaped edge chain catches a ball.

import "core:math"
import "core:testing"
import "moonhug:packages/engine"
import common "moonhug:tests/common"
import physics2d ".."
import b2 "vendor:box2d"

@(private = "file")
_cross :: proc(a, b, c: [2]f32) -> f32 {
	return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
}

@(private = "file")
_expect_pieces :: proc(t: ^testing.T, pieces: [][][2]f32, want_area: f32, what: string) {
	area: f32
	for piece in pieces {
		testing.expectf(t, len(piece) >= 3 && len(piece) <= b2.MAX_POLYGON_VERTICES, "%s: a piece of %d points", what, len(piece))
		for i in 0 ..< len(piece) {
			testing.expectf(t, _cross(piece[i], piece[(i + 1) % len(piece)], piece[(i + 2) % len(piece)]) >= -1e-5, "%s: piece %d is convex", what, i)
		}
		area += physics2d.polygon_area(piece)
	}
	testing.expectf(t, abs(area - want_area) < 1e-4, "%s: the pieces cover the area, %v of %v", what, area, want_area)
}

@(test)
physics2d_polygon_partition_keeps_shape :: proc(t: ^testing.T) {
	// An L, 4 x 4 with a 3 x 3 notch: area 7, concave at (1, 1).
	l := [][2]f32{{0, 0}, {4, 0}, {4, 1}, {1, 1}, {1, 4}, {0, 4}}
	pieces, ok := physics2d.polygon_partition(l, context.temp_allocator)
	testing.expect(t, ok, "the L partitions")
	if ok do _expect_pieces(t, pieces, 7, "L")
	// Clockwise input gives the same pieces.
	cw := [][2]f32{{0, 4}, {1, 4}, {1, 1}, {4, 1}, {4, 0}, {0, 0}}
	pieces, ok = physics2d.polygon_partition(cw, context.temp_allocator)
	testing.expect(t, ok, "a clockwise L partitions")
	if ok do _expect_pieces(t, pieces, 7, "clockwise L")
	// A regular 12-gon is convex but over the cap: at least two pieces.
	twelve: [dynamic][2]f32
	defer delete(twelve)
	physics2d.polygon_regular(&twelve, 12, 1)
	pieces, ok = physics2d.polygon_partition(twelve[:], context.temp_allocator)
	testing.expect(t, ok && len(pieces) >= 2, "a 12-gon splits")
	if ok do _expect_pieces(t, pieces, physics2d.polygon_area(twelve[:]), "12-gon")
	// A bow tie crosses itself: no ear, refused. A line is refused.
	_, ok = physics2d.polygon_partition([][2]f32{{0, 0}, {1, 1}, {1, 0}, {0, 1}}, context.temp_allocator)
	testing.expect(t, !ok, "a self-intersecting path is refused")
	_, ok = physics2d.polygon_partition([][2]f32{{0, 0}, {1, 0}, {2, 0}}, context.temp_allocator)
	testing.expect(t, !ok, "points on a line are refused")
}

@(private = "file")
_ball :: proc(w: ^engine.World, x, y: f32, radius: f32) -> engine.Transform_Handle {
	ball := engine.transform_new("Ball")
	bt := engine.pool_get(&w.transforms, engine.Handle(ball))
	bt.position = {x, y, 0}
	_, rb_ptr := engine.transform_add_comp(ball, .Rigidbody2D)
	rb := cast(^physics2d.Rigidbody2D)rb_ptr
	rb.body_type = .Dynamic
	rb.gravity_scale = 1
	_, circle_ptr := engine.transform_add_comp(ball, .CircleCollider2D)
	(cast(^physics2d.CircleCollider2D)circle_ptr).radius = radius
	return ball
}

@(test)
physics2d_polygon_collider_concave_floor :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// A static L. The ball dropped over the low arm lands on it at y = 1,
	// not on the hull's diagonal, which would hold it near y = 2.5.
	floor := engine.transform_new("L")
	_, pc_ptr := engine.transform_add_comp(floor, .PolygonCollider2D)
	pc := cast(^physics2d.PolygonCollider2D)pc_ptr
	clear(&pc.points)
	append(&pc.points, [2]f32{0, 0}, [2]f32{4, 0}, [2]f32{4, 1}, [2]f32{1, 1}, [2]f32{1, 4}, [2]f32{0, 4})
	ball := _ball(&tc.world, 2.5, 3, 0.25)
	for _ in 0 ..< 200 do physics2d.physics_step(1.0 / 60.0)
	testing.expectf(t, len(pc.shapes) >= 2 && !pc.build_failed, "the L is %d pieces", len(pc.shapes))
	y := engine.pool_get(&tc.world.transforms, engine.Handle(ball)).position.y
	testing.expectf(t, y > 1.2 && y < 1.3, "the ball rests on the low arm, y = %v", y)

	// A crossing path is refused with the component left without shapes.
	bad := engine.transform_new("Bowtie")
	_, bad_ptr := engine.transform_add_comp(bad, .PolygonCollider2D)
	bp := cast(^physics2d.PolygonCollider2D)bad_ptr
	clear(&bp.points)
	append(&bp.points, [2]f32{0, 0}, [2]f32{1, 1}, [2]f32{1, 0}, [2]f32{0, 1})
	physics2d.physics_step(1.0 / 60.0)
	testing.expect(t, bp.build_failed && len(bp.shapes) == 0, "a bow tie builds nothing")
}

@(test)
physics2d_polygon_collider_scale_and_rigidbody :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// A dynamic pentagon (the default path) on a floor, scaled 2x: it rests
	// with its lowest point on the floor. The pentagon starts with a point at
	// the top, so a flat edge is at the bottom, at -0.5 * cos(36°) * 2.
	floor := engine.transform_new("Floor")
	engine.pool_get(&tc.world.transforms, engine.Handle(floor)).position = {0, -2, 0}
	_, box_ptr := engine.transform_add_comp(floor, .BoxCollider2D)
	(cast(^physics2d.BoxCollider2D)box_ptr).size = {20, 1}

	body := engine.transform_new("Pentagon")
	bt := engine.pool_get(&tc.world.transforms, engine.Handle(body))
	bt.position = {0, 3, 0}
	bt.scale = {2, 2, 1}
	_, rb_ptr := engine.transform_add_comp(body, .Rigidbody2D)
	rb := cast(^physics2d.Rigidbody2D)rb_ptr
	rb.body_type = .Dynamic
	rb.gravity_scale = 1
	_, pc_ptr := engine.transform_add_comp(body, .PolygonCollider2D)
	pc := cast(^physics2d.PolygonCollider2D)pc_ptr
	for _ in 0 ..< 240 do physics2d.physics_step(1.0 / 60.0)
	testing.expect(t, len(pc.shapes) == 1, "a pentagon is one convex piece")
	y := engine.pool_get(&tc.world.transforms, engine.Handle(body)).position.y
	bottom := -2 + 0.5 + 0.5 * math.cos(f32(math.to_radians(36.0))) * 2
	testing.expectf(t, abs(y - bottom) < 0.05, "the scaled pentagon rests on its flat edge, y = %v, want %v", y, bottom)
}

@(test)
physics2d_edge_collider_catches_a_ball :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// A V of three points, wound so its solid side is the inside: the solid
	// side is to the right of the path's direction, so a floor runs from
	// right to left. A ball dropped over the left slope slides down into
	// the bottom and settles there, above the vertex.
	v := engine.transform_new("V")
	_, ec_ptr := engine.transform_add_comp(v, .EdgeCollider2D)
	ec := cast(^physics2d.EdgeCollider2D)ec_ptr
	clear(&ec.points)
	append(&ec.points, [2]f32{3, 3}, [2]f32{0, 0}, [2]f32{-3, 3})
	ball := _ball(&tc.world, -1.5, 3, 0.25)
	for _ in 0 ..< 400 do physics2d.physics_step(1.0 / 60.0)
	testing.expect(t, b2.Chain_IsValid(ec.chain) && len(ec.segments) == 2, "the chain has one segment per edge")
	p := engine.pool_get(&tc.world.transforms, engine.Handle(ball)).position
	testing.expectf(t, abs(p.x) < 0.2 && p.y > 0.2 && p.y < 0.5, "the ball settles in the V, at %v", p)

	// Wound the other way the V is solid outside: a ball passes through.
	engine.transform_destroy(ball)
	physics2d.cleanup_EdgeCollider2D(ec)
	ec.enabled = true
	ec.layers = 1
	append(&ec.points, [2]f32{-3, 3}, [2]f32{0, 0}, [2]f32{3, 3})
	through := _ball(&tc.world, -1.5, 3, 0.25)
	for _ in 0 ..< 200 do physics2d.physics_step(1.0 / 60.0)
	testing.expect(t, engine.pool_get(&tc.world.transforms, engine.Handle(through)).position.y < -5, "the back of the chain lets a ball through")
}
