package physics3d_tests

// End-to-end physics3d package test: authored components -> box3d sync ->
// step -> transform write-back, through the same path the app takes.

import "core:encoding/uuid"
import "core:fmt"
import "core:strings"
import "core:testing"
import "moonhug:packages/engine"
import common "moonhug:tests/common"
import physics3d ".."
import b3 "vendor:box3d"

@(test)
physics3d_dynamic_body_falls_onto_static_floor :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// Floor: box collider with NO rigidbody = implicit static body.
	floor := engine.transform_new("Floor")
	ft := engine.pool_get(&tc.world.transforms, engine.Handle(floor))
	ft.position = {0, -2, 0}
	_, box_ptr := engine.transform_add_comp(floor, .BoxCollider)
	box := cast(^physics3d.BoxCollider)box_ptr
	box.enabled = true
	box.size = {20, 1, 20}
	box.density = 1
	box.friction = 0.6

	// Ball: dynamic rigidbody + sphere collider, dropped from y = 3.
	ball := engine.transform_new("Ball")
	bt := engine.pool_get(&tc.world.transforms, engine.Handle(ball))
	bt.position = {0, 3, 0}
	_, rb_ptr := engine.transform_add_comp(ball, .Rigidbody)
	rb := cast(^physics3d.Rigidbody)rb_ptr
	rb.enabled = true
	rb.use_gravity = true
	_, sphere_ptr := engine.transform_add_comp(ball, .SphereCollider)
	sphere := cast(^physics3d.SphereCollider)sphere_ptr
	sphere.enabled = true
	sphere.radius = 0.5
	sphere.density = 1
	sphere.friction = 0.6

	// ~3.3 sim seconds at 60 Hz — plenty to fall 5m and settle.
	for _ in 0 ..< 200 {
		physics3d.physics_step(1.0 / 60.0)
	}

	y := engine.pool_get(&tc.world.transforms, engine.Handle(ball)).position.y
	// Floor top face is at -1.5; the resting ball center is ≈ -1.0.
	testing.expect(t, y < 0, "ball should have fallen from y=3")
	testing.expect(t, y > -1.6, "ball should rest ON the floor, not fall through")

	// Escape hatch resolves the live body.
	_, ok := physics3d.body_of(ball)
	testing.expect(t, ok, "body_of should find the live body")
}

@(test)
physics3d_transform_scale_affects_collider :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// 1x1x1 floor collider scaled 40x wide: only an effective 40x1x40 shape
	// can catch a ball dropped at x = 3 (the unscaled half-width is 0.5).
	floor := engine.transform_new("Floor")
	ft := engine.pool_get(&tc.world.transforms, engine.Handle(floor))
	ft.position = {0, -2, 0}
	ft.scale = {40, 1, 40}
	_, box_ptr := engine.transform_add_comp(floor, .BoxCollider)
	box := cast(^physics3d.BoxCollider)box_ptr
	box.enabled = true

	ball := engine.transform_new("Ball")
	bt := engine.pool_get(&tc.world.transforms, engine.Handle(ball))
	bt.position = {3, 3, 0}
	_, rb_ptr := engine.transform_add_comp(ball, .Rigidbody)
	rb := cast(^physics3d.Rigidbody)rb_ptr
	rb.enabled = true
	_, sphere_ptr := engine.transform_add_comp(ball, .SphereCollider)
	sphere := cast(^physics3d.SphereCollider)sphere_ptr
	sphere.enabled = true

	for _ in 0 ..< 200 {
		physics3d.physics_step(1.0 / 60.0)
	}

	y := engine.pool_get(&tc.world.transforms, engine.Handle(ball)).position.y
	testing.expect(t, y > -1.6, "scaled floor should catch the ball at x=3")
}

@(test)
physics3d_kinematic_body_pushes_dynamic :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// Kinematic pusher moved via its TRANSFORM (the script-driven pattern).
	// Velocity-driven follow makes the step carry it into the crate — a
	// teleporting follow would never impart momentum.
	pusher := engine.transform_new("Pusher")
	pt := engine.pool_get(&tc.world.transforms, engine.Handle(pusher))
	pt.position = {0, 0, 0}
	_, prb_ptr := engine.transform_add_comp(pusher, .Rigidbody)
	prb := cast(^physics3d.Rigidbody)prb_ptr
	prb.enabled = true
	prb.is_kinematic = true
	_, pbox_ptr := engine.transform_add_comp(pusher, .BoxCollider)
	pbox := cast(^physics3d.BoxCollider)pbox_ptr
	pbox.enabled = true

	// Dynamic crate ahead on +x, gravity off so it can only move by contact.
	crate := engine.transform_new("Crate")
	ct := engine.pool_get(&tc.world.transforms, engine.Handle(crate))
	ct.position = {1.2, 0, 0}
	_, crb_ptr := engine.transform_add_comp(crate, .Rigidbody)
	crb := cast(^physics3d.Rigidbody)crb_ptr
	crb.enabled = true
	crb.use_gravity = false
	_, cbox_ptr := engine.transform_add_comp(crate, .BoxCollider)
	cbox := cast(^physics3d.BoxCollider)cbox_ptr
	cbox.enabled = true

	// Drive the pusher 2 m/s along +x for one second of sim time.
	dt :: f32(1.0 / 60.0)
	for _ in 0 ..< 60 {
		pt = engine.pool_get(&tc.world.transforms, engine.Handle(pusher))
		pt.position.x += 2 * dt
		physics3d.physics_step(dt)
	}

	x := engine.pool_get(&tc.world.transforms, engine.Handle(crate)).position.x
	// Pusher front face ends at 2.5; the crate center must sit past 3.0
	// minus a small solver margin.
	testing.expect(t, x > 2.8, "kinematic pusher should shove the dynamic crate along +x")
}

// Collision layers: two shapes collide when each one's layers meet the other's
// mask, which is the collision matrix's rows for its layers plus the includes
// and minus the excludes of the collider and its body. The default matrix lets
// every pair collide: ball B lands. Ball A excludes the floor's layer on its
// collider and ball C on its body: both fall through with no contact.
@(test)
physics3d_layer_overrides_filter_contacts :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	floor := engine.transform_new("Floor")
	engine.pool_get(&tc.world.transforms, engine.Handle(floor)).position = {0, -2, 0}
	_, box_ptr := engine.transform_add_comp(floor, .BoxCollider)
	box := cast(^physics3d.BoxCollider)box_ptr
	box.enabled = true
	box.size = {20, 1, 20}
	testing.expect_value(t, box.layers, u32(1))
	testing.expect_value(t, box.layer_overrides, physics3d.Physics3D_Layer_Overrides{})
	// The picker reads the names from the plugin's own layer domain.
	testing.expect_value(t, engine.layer_name(physics3d.LAYER_DOMAIN, 0), "Default")

	a := _layer_ball(tc, "A", -4, layer = 1 << 3, exclude = 1)
	b := _layer_ball(tc, "B", 0, layer = 1 << 3)
	c := _layer_ball(tc, "C", 4, layer = 1 << 3, body_exclude = 1)

	a_hit, b_hit, c_hit: bool
	for _ in 0 ..< 200 {
		physics3d.physics_step(1.0 / 60.0)
		for e in physics3d.contact_begin_events() {
			if _pair_is(e, a, floor) do a_hit = true
			if _pair_is(e, b, floor) do b_hit = true
			if _pair_is(e, c, floor) do c_hit = true
		}
	}

	testing.expect(t, !a_hit, "A's collider excludes the floor's layer: no contact")
	testing.expect(t, b_hit, "B and the floor collide by the matrix: contact")
	testing.expect(t, !c_hit, "C's body excludes the floor's layer: no contact")
	ay := engine.pool_get(&tc.world.transforms, engine.Handle(a)).position.y
	by := engine.pool_get(&tc.world.transforms, engine.Handle(b)).position.y
	testing.expect(t, ay < -3, "A falls through the floor")
	testing.expect(t, by > -1.6, "B rests on the floor")

	// The layers and the computed mask reach box3d as the shape filter.
	sphere := _layer_sphere(tc, a)
	f := b3.Shape_GetFilter(sphere.shape)
	testing.expect_value(t, f.categoryBits, u64(1 << 3))
	testing.expect_value(t, f.maskBits, u64(~u32(0) &~ 1))
}

// An edit of the layer overrides on a live collider reaches its shape on the
// next step.
@(test)
physics3d_layer_overrides_edit_applies_live :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	floor := engine.transform_new("Floor")
	engine.pool_get(&tc.world.transforms, engine.Handle(floor)).position = {0, -2, 0}
	_, box_ptr := engine.transform_add_comp(floor, .BoxCollider)
	box := cast(^physics3d.BoxCollider)box_ptr
	box.enabled = true
	box.size = {20, 1, 20}

	ball := _layer_ball(tc, "Ball", 0, layer = 1, exclude = ~u32(0))
	physics3d.physics_step(1.0 / 60.0)
	sphere := _layer_sphere(tc, ball)
	testing.expect_value(t, b3.Shape_GetFilter(sphere.shape).maskBits, u64(0))

	sphere.exclude = 0
	for _ in 0 ..< 200 {
		physics3d.physics_step(1.0 / 60.0)
	}
	testing.expect_value(t, b3.Shape_GetFilter(sphere.shape).maskBits, u64(~u32(0)))
	y := engine.pool_get(&tc.world.transforms, engine.Handle(ball)).position.y
	testing.expect(t, y > -1.6, "the ball lands once it stops excluding the floor's layer")
}

@(private = "file")
_layer_ball :: proc(tc: ^common.TestCtx, name: string, x: f32, layer: u32, exclude: u32 = 0, body_exclude: u32 = 0) -> engine.Transform_Handle {
	ball := engine.transform_new(name)
	engine.pool_get(&tc.world.transforms, engine.Handle(ball)).position = {x, 3, 0}
	_, rb_ptr := engine.transform_add_comp(ball, .Rigidbody)
	rb := cast(^physics3d.Rigidbody)rb_ptr
	rb.enabled = true
	rb.use_gravity = true
	rb.exclude = body_exclude
	_, sphere_ptr := engine.transform_add_comp(ball, .SphereCollider)
	sphere := cast(^physics3d.SphereCollider)sphere_ptr
	sphere.enabled = true
	sphere.layers = layer
	sphere.exclude = exclude
	return ball
}

@(private = "file")
_layer_sphere :: proc(tc: ^common.TestCtx, tH: engine.Transform_Handle) -> ^physics3d.SphereCollider {
	t := engine.pool_get(&tc.world.transforms, engine.Handle(tH))
	owned, idx := engine.transform_find_comp(t, .SphereCollider)
	assert(idx >= 0, "the ball has a SphereCollider")
	return engine.pool_get(physics3d.sphere_colliders(&tc.world), owned.handle)
}

@(private = "file")
_pair_is :: proc(c: physics3d.Contact, x, y: engine.Transform_Handle) -> bool {
	return (c.a == x && c.b == y) || (c.a == y && c.b == x)
}

// The plugin's layers asset: a new one names layer 0 "Default" and lets every
// pair collide, a file loads its names and rows, and a file of another type
// does not load.
@(test)
physics3d_layers_asset :: proc(t: ^testing.T) {
	l: physics3d.Physics3D_Layers
	physics3d.reset_Physics3D_Layers(&l)
	defer physics3d.cleanup_Physics3D_Layers(&l)
	testing.expect_value(t, l.names[0], "Default")
	testing.expect_value(t, l.names[1], "")
	for row in l.rows do testing.expect_value(t, row, ~u32(0))

	tg := engine.get_guid_by_typeid(physics3d.Physics3D_Layers)
	data := fmt.tprintf(`{{"__type_guid": "%s", "names": ["Default", "Player"], "rows": [4294967291, 4294967295, 4294967294]}}`, uuid.to_string(tg, context.temp_allocator))
	got, ok := engine.asset_parse_as(transmute([]u8)data, physics3d.Physics3D_Layers)
	defer physics3d.cleanup_Physics3D_Layers(&got)
	testing.expect(t, ok, "a Physics 3D Layers file loads")
	testing.expect_value(t, got.names[1], "Player")
	testing.expect_value(t, got.rows[0], u32(4294967291))
	testing.expect_value(t, got.rows[2], u32(4294967294))

	sparse, sok := engine.asset_parse_as(transmute([]u8)fmt.tprintf(`{{"__type_guid": "%s"}}`, uuid.to_string(tg, context.temp_allocator)), physics3d.Physics3D_Layers)
	defer physics3d.cleanup_Physics3D_Layers(&sparse)
	testing.expect(t, sok, "a file without fields loads")
	testing.expect_value(t, sparse.names[0], "Default")
	testing.expect_value(t, sparse.rows[5], ~u32(0))

	_, other_ok := engine.asset_parse_as(transmute([]u8)string(`{"__type_guid": "6a0f6f86-3a55-4a8e-a2a1-0d6c43f4e2ff"}`), physics3d.Physics3D_Layers)
	testing.expect(t, !other_ok, "a file of another type does not load")
}

// A collider's mask: the active matrix's rows for its layers, plus the
// collider's and the body's includes, minus both excludes. An inspector edit
// of the asset the settings name reaches the names and the mask before it is
// saved, an edit of another asset does not. Without a setting layer 0 is
// "Default" and every pair collides.
@(test)
physics3d_collision_mask :: proc(t: ^testing.T) {
	physics3d.layers_sync()
	prev := physics3d.physics3d_settings
	defer {
		physics3d.physics3d_settings = prev
		physics3d.layers_sync()
	}
	testing.expect_value(t, engine.layer_name(physics3d.LAYER_DOMAIN, 0), "Default")

	// An asset the settings name but the asset db lacks: the sync falls back
	// to the built-in layers and remembers the guid, so its document's preview
	// applies.
	layers_guid := engine.Asset_GUID(uuid.read("6a0f6f86-3a55-4a8e-a2a1-0d6c43f4e236") or_else {})
	physics3d.physics3d_settings.layers = layers_guid
	physics3d.layers_sync()

	everything := ~u32(0)
	testing.expect_value(t, physics3d.matrix_collides_with(1 << 3), everything)
	testing.expect_value(t, physics3d.collision_mask(1 << 3, {exclude = 1}, {exclude = 4}), everything &~ 5)

	// Layers 1 and 2 do not collide, every other pair does.
	l: physics3d.Physics3D_Layers
	physics3d.reset_Physics3D_Layers(&l)
	defer physics3d.cleanup_Physics3D_Layers(&l)
	l.names[1] = strings.clone("Player")
	l.rows[1] &~= 1 << 2
	l.rows[2] &~= 1 << 1
	physics3d.layers_preview(layers_guid, l)
	testing.expect_value(t, engine.layer_name(physics3d.LAYER_DOMAIN, 1), "Player")
	testing.expect_value(t, physics3d.matrix_collides_with(1 << 1), everything &~ (1 << 2))
	testing.expect_value(t, physics3d.matrix_collides_with(1 << 1 | 1 << 3), everything) // layer 3's row takes 2 back
	testing.expect_value(t, physics3d.collision_mask(1 << 1, {}, {}), everything &~ (1 << 2))
	testing.expect_value(t, physics3d.collision_mask(1 << 1, {include = 1 << 2}, {}), everything)
	testing.expect_value(t, physics3d.collision_mask(1 << 1, {}, {include = 1 << 2}), everything)
	testing.expect_value(t, physics3d.collision_mask(1 << 1, {include = 1 << 2}, {exclude = 1 << 2}), everything &~ (1 << 2))

	other: physics3d.Physics3D_Layers
	physics3d.layers_preview(engine.Asset_GUID(uuid.read("6a0f6f86-3a55-4a8e-a2a1-0d6c43f4e237") or_else {}), other)
	testing.expect_value(t, physics3d.matrix_collides_with(1 << 1), everything &~ (1 << 2))
	testing.expect_value(t, engine.layer_name(physics3d.LAYER_DOMAIN, 1), "Player")
}
