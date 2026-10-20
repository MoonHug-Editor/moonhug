package physics2d_tests

// End-to-end physics2d package test: authored components -> box2d sync ->
// step -> transform write-back, through the same path the app takes.
// Ships WITH the package (docs/core/Plugins.md) — `mh test` runs every
// packages/*/tests suite after the central one.

import "core:encoding/uuid"
import "core:fmt"
import "core:strings"
import "core:testing"
import "moonhug:packages/engine"
import common "moonhug:tests/common"
import physics2d ".."
import b2 "vendor:box2d"

@(test)
physics2d_dynamic_body_falls_onto_static_floor :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// Floor: box collider with NO rigidbody = implicit static body.
	floor := engine.transform_new("Floor")
	ft := engine.pool_get(&tc.world.transforms, engine.Handle(floor))
	ft.position = {0, -2, 0}
	_, box_ptr := engine.transform_add_comp(floor, .BoxCollider2D)
	box := cast(^physics2d.BoxCollider2D)box_ptr
	box.enabled = true
	box.size = {20, 1}
	box.density = 1

	// Ball: dynamic rigidbody + circle collider, dropped from y = 3.
	ball := engine.transform_new("Ball")
	bt := engine.pool_get(&tc.world.transforms, engine.Handle(ball))
	bt.position = {0, 3, 0}
	_, rb_ptr := engine.transform_add_comp(ball, .Rigidbody2D)
	rb := cast(^physics2d.Rigidbody2D)rb_ptr
	rb.enabled = true
	rb.body_type = .Dynamic
	rb.gravity_scale = 1
	_, circle_ptr := engine.transform_add_comp(ball, .CircleCollider2D)
	circle := cast(^physics2d.CircleCollider2D)circle_ptr
	circle.enabled = true
	circle.radius = 0.5
	circle.density = 1

	// ~3.3 sim seconds at 60 Hz — plenty to fall 5m and settle.
	for _ in 0 ..< 200 {
		physics2d.physics_step(1.0 / 60.0)
	}

	y := engine.pool_get(&tc.world.transforms, engine.Handle(ball)).position.y
	// Floor top edge is at -1.5; the resting ball center is ≈ -1.0.
	testing.expect(t, y < 0, "ball should have fallen from y=3")
	testing.expect(t, y > -1.6, "ball should rest ON the floor, not fall through")

	// Escape hatch resolves the live body.
	_, ok := physics2d.body_of(ball)
	testing.expect(t, ok, "body_of should find the live body")
}

@(test)
physics2d_transform_scale_affects_collider :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// 1x1 floor collider scaled 40x wide: only an effective 40x1 shape can
	// catch a ball dropped at x = 3 (the unscaled half-width is 0.5).
	floor := engine.transform_new("Floor")
	ft := engine.pool_get(&tc.world.transforms, engine.Handle(floor))
	ft.position = {0, -2, 0}
	ft.scale = {40, 1, 1}
	_, box_ptr := engine.transform_add_comp(floor, .BoxCollider2D)
	box := cast(^physics2d.BoxCollider2D)box_ptr
	box.enabled = true

	ball := engine.transform_new("Ball")
	bt := engine.pool_get(&tc.world.transforms, engine.Handle(ball))
	bt.position = {3, 3, 0}
	_, rb_ptr := engine.transform_add_comp(ball, .Rigidbody2D)
	rb := cast(^physics2d.Rigidbody2D)rb_ptr
	rb.enabled = true
	rb.body_type = .Dynamic
	rb.gravity_scale = 1
	_, circle_ptr := engine.transform_add_comp(ball, .CircleCollider2D)
	circle := cast(^physics2d.CircleCollider2D)circle_ptr
	circle.enabled = true

	for _ in 0 ..< 200 {
		physics2d.physics_step(1.0 / 60.0)
	}

	y := engine.pool_get(&tc.world.transforms, engine.Handle(ball)).position.y
	testing.expect(t, y > -1.6, "scaled floor should catch the ball at x=3")
}

@(test)
physics2d_kinematic_body_pushes_dynamic :: proc(t: ^testing.T) {
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
	_, prb_ptr := engine.transform_add_comp(pusher, .Rigidbody2D)
	prb := cast(^physics2d.Rigidbody2D)prb_ptr
	prb.enabled = true
	prb.body_type = .Kinematic
	_, pbox_ptr := engine.transform_add_comp(pusher, .BoxCollider2D)
	pbox := cast(^physics2d.BoxCollider2D)pbox_ptr
	pbox.enabled = true

	// Dynamic crate ahead on +x, gravity off so it can only move by contact.
	crate := engine.transform_new("Crate")
	ct := engine.pool_get(&tc.world.transforms, engine.Handle(crate))
	ct.position = {1.2, 0, 0}
	_, crb_ptr := engine.transform_add_comp(crate, .Rigidbody2D)
	crb := cast(^physics2d.Rigidbody2D)crb_ptr
	crb.enabled = true
	crb.body_type = .Dynamic
	crb.gravity_scale = 0
	_, cbox_ptr := engine.transform_add_comp(crate, .BoxCollider2D)
	cbox := cast(^physics2d.BoxCollider2D)cbox_ptr
	cbox.enabled = true

	// Drive the pusher 2 m/s along +x for one second of sim time.
	dt :: f32(1.0 / 60.0)
	for _ in 0 ..< 60 {
		pt = engine.pool_get(&tc.world.transforms, engine.Handle(pusher))
		pt.position.x += 2 * dt
		physics2d.physics_step(dt)
	}

	x := engine.pool_get(&tc.world.transforms, engine.Handle(crate)).position.x
	// Pusher front face ends at 2.5; the crate center must sit past 3.0
	// minus a small solver margin.
	testing.expect(t, x > 2.8, "kinematic pusher should shove the dynamic crate along +x")
}

// Snapshot/restore (docs/core/Simulate.md) must leave no box2d bodies behind.
// Restore destroys every object in the scene, which fires on_destroy_* the same
// way a manual delete does; this pins that the physics side really is released.
@(test)
physics2d_bodies_released_on_scene_restore :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	scene := engine.sm_scene_get_active()
	testing.expect(t, scene != nil)
	if scene == nil do return
	root := engine.Transform_Handle(scene.root.handle)

	floor := engine.transform_new("Floor", root)
	engine.pool_get(&tc.world.transforms, engine.Handle(floor)).position = {0, -2, 0}
	_, box_ptr := engine.transform_add_comp(floor, .BoxCollider2D)
	box := cast(^physics2d.BoxCollider2D)box_ptr
	box.enabled = true
	box.size = {20, 1}
	box.density = 1

	ball := engine.transform_new("Ball", root)
	engine.pool_get(&tc.world.transforms, engine.Handle(ball)).position = {0, 3, 0}
	_, rb_ptr := engine.transform_add_comp(ball, .Rigidbody2D)
	rb := cast(^physics2d.Rigidbody2D)rb_ptr
	rb.enabled = true
	rb.body_type = .Dynamic
	rb.gravity_scale = 1
	_, circle_ptr := engine.transform_add_comp(ball, .CircleCollider2D)
	circle := cast(^physics2d.CircleCollider2D)circle_ptr
	circle.enabled = true
	circle.radius = 0.5
	circle.density = 1

	snapshot, ok := engine.scene_serialize(scene)
	testing.expect(t, ok, "captured the pre-simulation snapshot")
	if !ok do return
	defer delete(snapshot)

	// "Play": step until the ball lands, so bodies are live and touching.
	for _ in 0 ..< 200 {
		physics2d.physics_step(1.0 / 60.0)
	}
	ball_body, live := physics2d.body_of(ball)
	testing.expect(t, live, "ball body is live before restore")
	if !live do return
	floor_body := box.static_body
	floor_live := b2.Body_IsValid(floor_body)
	testing.expect(t, floor_live, "floor's implicit static body is live before restore")

	// "Stop".
	restored := engine.scene_reload_in_place_bytes(
		scene, snapshot, scene.asset_guid, scene.path)
	testing.expect(t, restored != nil, "restore succeeded")
	if restored == nil do return
	tc.scene = restored

	testing.expect(t, !b2.Body_IsValid(ball_body),
		"ball's box2d body is destroyed by restore")
	if floor_live {
		testing.expect(t, !b2.Body_IsValid(floor_body),
			"floor's implicit static body is destroyed by restore")
	}

	// The restored scene re-syncs its own bodies on the next step: no leak, and
	// the objects are usable again.
	physics2d.physics_step(1.0 / 60.0)
	new_ball := engine.Transform_Handle{}
	it := engine.pool_iterator(&tc.world.transforms)
	for tr, h in engine.pool_next(&it) {
		if tr.name != "Ball" do continue
		th := h
		th.type_key = .Transform
		new_ball = engine.Transform_Handle(th)
		break
	}
	testing.expect(t, new_ball != {}, "Ball is back after restore")
	if new_ball != {} {
		_, reborn := physics2d.body_of(new_ball)
		testing.expect(t, reborn, "restored Ball gets a fresh live body")
	}
}

// Collision layers: two shapes collide when each one's layers meet the other's
// mask, which is the collision matrix's rows for its layers plus the includes
// and minus the excludes of the collider and its body. The default matrix lets
// every pair collide: ball B lands. Ball A excludes the floor's layer on its
// collider and ball C on its body: both fall through with no contact.
@(test)
physics2d_layer_overrides_filter_contacts :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	floor := engine.transform_new("Floor")
	engine.pool_get(&tc.world.transforms, engine.Handle(floor)).position = {0, -2, 0}
	_, box_ptr := engine.transform_add_comp(floor, .BoxCollider2D)
	box := cast(^physics2d.BoxCollider2D)box_ptr
	box.enabled = true
	box.size = {20, 1}
	testing.expect_value(t, box.layers, u32(1))
	testing.expect_value(t, box.layer_overrides, physics2d.Physics2D_Layer_Overrides{})
	// The picker reads the names from the plugin's own layer domain.
	testing.expect_value(t, engine.layer_name(physics2d.LAYER_DOMAIN, 0), "Default")

	// A excludes the floor's layer on its collider, C on its body, B has no
	// override: the default matrix lets every pair collide.
	a := _layer_ball(tc, "A", -4, layer = 1 << 3, exclude = 1)
	b := _layer_ball(tc, "B", 0, layer = 1 << 3)
	c := _layer_ball(tc, "C", 4, layer = 1 << 3, body_exclude = 1)

	a_hit, b_hit, c_hit: bool
	for _ in 0 ..< 200 {
		physics2d.physics_step(1.0 / 60.0)
		for e in physics2d.contact_begin_events() {
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

	// The layers and the computed mask reach box2d as the shape filter.
	circle := _layer_circle(tc, a)
	f := b2.Shape_GetFilter(circle.shape)
	testing.expect_value(t, f.categoryBits, u64(1 << 3))
	testing.expect_value(t, f.maskBits, u64(~u32(0) &~ 1))
}

// An edit of the layer overrides on a live collider reaches its shape on the
// next step.
@(test)
physics2d_layer_overrides_edit_applies_live :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	floor := engine.transform_new("Floor")
	engine.pool_get(&tc.world.transforms, engine.Handle(floor)).position = {0, -2, 0}
	_, box_ptr := engine.transform_add_comp(floor, .BoxCollider2D)
	box := cast(^physics2d.BoxCollider2D)box_ptr
	box.enabled = true
	box.size = {20, 1}

	ball := _layer_ball(tc, "Ball", 0, layer = 1, exclude = ~u32(0))
	physics2d.physics_step(1.0 / 60.0)
	circle := _layer_circle(tc, ball)
	testing.expect_value(t, b2.Shape_GetFilter(circle.shape).maskBits, u64(0))

	circle.exclude = 0
	for _ in 0 ..< 200 {
		physics2d.physics_step(1.0 / 60.0)
	}
	testing.expect_value(t, b2.Shape_GetFilter(circle.shape).maskBits, u64(~u32(0)))
	y := engine.pool_get(&tc.world.transforms, engine.Handle(ball)).position.y
	testing.expect(t, y > -1.6, "the ball lands once it stops excluding the floor's layer")
}

@(private = "file")
_layer_ball :: proc(tc: ^common.TestCtx, name: string, x: f32, layer: u32, exclude: u32 = 0, body_exclude: u32 = 0) -> engine.Transform_Handle {
	ball := engine.transform_new(name)
	engine.pool_get(&tc.world.transforms, engine.Handle(ball)).position = {x, 3, 0}
	_, rb_ptr := engine.transform_add_comp(ball, .Rigidbody2D)
	rb := cast(^physics2d.Rigidbody2D)rb_ptr
	rb.enabled = true
	rb.body_type = .Dynamic
	rb.gravity_scale = 1
	rb.exclude = body_exclude
	_, circle_ptr := engine.transform_add_comp(ball, .CircleCollider2D)
	circle := cast(^physics2d.CircleCollider2D)circle_ptr
	circle.enabled = true
	circle.layers = layer
	circle.exclude = exclude
	return ball
}

@(private = "file")
_layer_circle :: proc(tc: ^common.TestCtx, tH: engine.Transform_Handle) -> ^physics2d.CircleCollider2D {
	t := engine.pool_get(&tc.world.transforms, engine.Handle(tH))
	owned, idx := engine.transform_find_comp(t, .CircleCollider2D)
	assert(idx >= 0, "the ball has a CircleCollider2D")
	return engine.pool_get(physics2d.circle_collider2_ds(&tc.world), owned.handle)
}

@(private = "file")
_pair_is :: proc(c: physics2d.Contact, x, y: engine.Transform_Handle) -> bool {
	return (c.a == x && c.b == y) || (c.a == y && c.b == x)
}

// The plugin's layers asset: a new one names layer 0 "Default" and lets every
// pair collide, a file loads its names and rows, and a file of another type
// does not load.
@(test)
physics2d_layers_asset :: proc(t: ^testing.T) {
	l: physics2d.Physics2D_Layers
	physics2d.reset_Physics2D_Layers(&l)
	defer physics2d.cleanup_Physics2D_Layers(&l)
	testing.expect_value(t, l.names[0], "Default")
	testing.expect_value(t, l.names[1], "")
	for row in l.rows do testing.expect_value(t, row, ~u32(0))

	tg := engine.get_guid_by_typeid(physics2d.Physics2D_Layers)
	data := fmt.tprintf(`{{"__type_guid": "%s", "names": ["Default", "Player"], "rows": [4294967291, 4294967295, 4294967294]}}`, uuid.to_string(tg, context.temp_allocator))
	got, ok := engine.asset_parse_as(transmute([]u8)data, physics2d.Physics2D_Layers)
	defer physics2d.cleanup_Physics2D_Layers(&got)
	testing.expect(t, ok, "a Physics 2D Layers file loads")
	testing.expect_value(t, got.names[1], "Player")
	testing.expect_value(t, got.rows[0], u32(4294967291))
	testing.expect_value(t, got.rows[2], u32(4294967294))

	sparse, sok := engine.asset_parse_as(transmute([]u8)fmt.tprintf(`{{"__type_guid": "%s"}}`, uuid.to_string(tg, context.temp_allocator)), physics2d.Physics2D_Layers)
	defer physics2d.cleanup_Physics2D_Layers(&sparse)
	testing.expect(t, sok, "a file without fields loads")
	testing.expect_value(t, sparse.names[0], "Default")
	testing.expect_value(t, sparse.rows[5], ~u32(0))

	_, other_ok := engine.asset_parse_as(transmute([]u8)string(`{"__type_guid": "6a0f6f86-3a55-4a8e-a2a1-0d6c43f4e2ff"}`), physics2d.Physics2D_Layers)
	testing.expect(t, !other_ok, "a file of another type does not load")
}

// A collider's mask: the active matrix's rows for its layers, plus the
// collider's and the body's includes, minus both excludes. An inspector edit
// of the asset the settings name reaches the names and the mask before it is
// saved, an edit of another asset does not. Without a setting layer 0 is
// "Default" and every pair collides.
@(test)
physics2d_collision_mask :: proc(t: ^testing.T) {
	physics2d.layers_sync()
	prev := physics2d.physics2d_settings
	defer {
		physics2d.physics2d_settings = prev
		physics2d.layers_sync()
	}
	testing.expect_value(t, engine.layer_name(physics2d.LAYER_DOMAIN, 0), "Default")

	// An asset the settings name but the asset db lacks: the sync falls back
	// to the built-in layers and remembers the guid, so its document's preview
	// applies.
	layers_guid := engine.Asset_GUID(uuid.read("6a0f6f86-3a55-4a8e-a2a1-0d6c43f4e226") or_else {})
	physics2d.physics2d_settings.layers = layers_guid
	physics2d.layers_sync()

	everything := ~u32(0)
	testing.expect_value(t, physics2d.matrix_collides_with(1 << 3), everything)
	testing.expect_value(t, physics2d.collision_mask(1 << 3, {exclude = 1}, {exclude = 4}), everything &~ 5)

	// Layers 1 and 2 do not collide, every other pair does.
	l: physics2d.Physics2D_Layers
	physics2d.reset_Physics2D_Layers(&l)
	defer physics2d.cleanup_Physics2D_Layers(&l)
	l.names[1] = strings.clone("Player")
	l.rows[1] &~= 1 << 2
	l.rows[2] &~= 1 << 1
	physics2d.layers_preview(layers_guid, l)
	testing.expect_value(t, engine.layer_name(physics2d.LAYER_DOMAIN, 1), "Player")
	testing.expect_value(t, physics2d.matrix_collides_with(1 << 1), everything &~ (1 << 2))
	testing.expect_value(t, physics2d.matrix_collides_with(1 << 1 | 1 << 3), everything) // layer 3's row takes 2 back
	testing.expect_value(t, physics2d.collision_mask(1 << 1, {}, {}), everything &~ (1 << 2))
	testing.expect_value(t, physics2d.collision_mask(1 << 1, {include = 1 << 2}, {}), everything)
	testing.expect_value(t, physics2d.collision_mask(1 << 1, {}, {include = 1 << 2}), everything)
	testing.expect_value(t, physics2d.collision_mask(1 << 1, {include = 1 << 2}, {exclude = 1 << 2}), everything &~ (1 << 2))

	other: physics2d.Physics2D_Layers
	physics2d.layers_preview(engine.Asset_GUID(uuid.read("6a0f6f86-3a55-4a8e-a2a1-0d6c43f4e227") or_else {}), other)
	testing.expect_value(t, physics2d.matrix_collides_with(1 << 1), everything &~ (1 << 2))
	testing.expect_value(t, engine.layer_name(physics2d.LAYER_DOMAIN, 1), "Player")
}
