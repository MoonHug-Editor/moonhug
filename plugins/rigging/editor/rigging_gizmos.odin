package rigging_editor

// Rigging gizmos, for the components in the selection:
// - TwoBoneIK: the limb as two lines, a line from the tip to the target and
//   a dashed one from the middle joint to the hint.
// - SpringBones: every swinging bone as a line with a sphere of `radius` at
//   its end, and the colliders it stays out of.
// - SpringBoneCollider: its sphere.

import "moonhug:packages/engine"
import "moonhug:libs/gizmos"
import "moonhug:editor/handles"
import rigging "moonhug:packages/rigging"

RIG_COLOR :: [4]f32{1, 0.75, 0.2, 1}
RIG_TARGET_COLOR :: [4]f32{0.3, 0.9, 1, 1}
RIG_COLLIDER_COLOR :: [4]f32{1, 0.4, 0.8, 0.8}

@(comp_on_draw_gizmos={component=TwoBoneIK})
comp_on_draw_gizmos_TwoBoneIK :: proc(ik: ^rigging.TwoBoneIK, ctx: handles.Gizmo_Context) {
	if .In_Selection not_in ctx.state do return
	root, mid, tip, ok := rigging.two_bone_joints(ik)
	if !ok do return
	w := engine.ctx_world()
	a := engine.transform_world(root).position
	b := engine.transform_world(mid).position
	c := engine.transform_world(tip).position
	gizmos.with_depth_test(false)
	gizmos.with_color(RIG_COLOR)
	gizmos.line(a, b)
	gizmos.line(b, c)
	gizmos.with_color(RIG_TARGET_COLOR)
	if target := engine.Transform_Handle(ik.target.handle); engine.pool_valid(&w.transforms, engine.Handle(target)) {
		goal := engine.transform_world(target).position
		gizmos.line(c, goal)
		gizmos.wire_sphere(goal, handles.world_per_pixels(goal, 6), 12)
	}
	if hint := engine.Transform_Handle(ik.hint.handle); engine.pool_valid(&w.transforms, engine.Handle(hint)) {
		gizmos.line_dashed(b, engine.transform_world(hint).position, handles.world_per_pixels(b, 6))
	}
}

@(comp_on_draw_gizmos={component=SpringBones})
comp_on_draw_gizmos_SpringBones :: proc(s: ^rigging.SpringBones, ctx: handles.Gizmo_Context) {
	if .In_Selection not_in ctx.state do return
	w := engine.ctx_world()
	gizmos.with_depth_test(false)
	gizmos.with_color(RIG_COLOR)
	// The hierarchy as it is now, so the chain shows before the game runs.
	stack := make([dynamic]engine.Transform_Handle, context.temp_allocator)
	append(&stack, rigging.spring_bones_root(s))
	for len(stack) > 0 {
		h := pop(&stack)
		t := engine.pool_get(&w.transforms, engine.Handle(h))
		if t == nil do continue
		for c in t.children do append(&stack, engine.Transform_Handle(c.handle))
		if len(t.children) == 0 do continue
		head := engine.transform_world(h).position
		tail := engine.transform_world(engine.Transform_Handle(t.children[0].handle)).position
		gizmos.line(head, tail)
		if s.radius > 0 do gizmos.wire_sphere(tail, s.radius, 12)
	}
	under := engine.Transform_Handle(s.colliders.handle)
	if !engine.pool_valid(&w.transforms, engine.Handle(under)) do return
	pool := rigging.spring_bone_colliders(w)
	if pool == nil do return
	gizmos.with_color(RIG_COLLIDER_COLOR)
	it := engine.pool_iterator(pool)
	for c, _ in engine.pool_next(&it) {
		if !c.enabled || (c.owner != under && !engine.transform_is_under(c.owner, under)) do continue
		center, radius := rigging.spring_collider_sphere(c)
		gizmos.wire_sphere(center, radius)
	}
}

@(comp_on_draw_gizmos={component=SpringBoneCollider})
comp_on_draw_gizmos_SpringBoneCollider :: proc(c: ^rigging.SpringBoneCollider, ctx: handles.Gizmo_Context) {
	if .In_Selection not_in ctx.state do return
	gizmos.with_color(RIG_COLLIDER_COLOR)
	center, radius := rigging.spring_collider_sphere(c)
	gizmos.wire_sphere(center, radius)
}
