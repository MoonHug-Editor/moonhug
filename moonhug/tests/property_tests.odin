package tests

// inspector.property (docs/InspectorProperty.md): a field addressed from an
// owner and a dotted path. The resolver is what an MCP property write and the
// timeline animator's proxy rows share, so the path grammar and the two
// addresses — the value, and the array an override names — are pinned here.

import "core:testing"
import "../engine"
import "../editor/inspector"
import anim "moonhug:packages/animation"

@(private = "file")
_animator_with_states :: proc() -> (^anim.TimelineAnimator, engine.Handle) {
	owner := engine.transform_new("Animator")
	comp, ptr := engine.transform_add_comp(owner, .TimelineAnimator)
	a := cast(^anim.TimelineAnimator)ptr
	a.layers = make([dynamic]anim.Animator_Layer)
	append(&a.layers, anim.Animator_Layer{weight = 1, states = make([dynamic]anim.Timeline_State)})
	append(&a.layers[0].states, anim.Timeline_State{id = 1, speed = 1})
	append(&a.layers[0].states, anim.Timeline_State{id = 2, speed = 2})
	return a, comp.handle
}

@(test)
test_property_plain_field_names_itself :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "")
	context.user_ptr = &tc.uc
	defer teardown(tc)

	a, comp := _animator_with_states()
	p, ok := inspector.inspect_comp(comp)
	testing.expect(t, ok)
	if !ok do return

	w, err := inspector.property(p, "layers")
	testing.expect_value(t, err, inspector.Resolve_Error.None)
	testing.expect(t, w.ptr == rawptr(&a.layers), "the pointer is the field")
	testing.expect(t, w.tid == typeid_of([dynamic]anim.Animator_Layer))
	testing.expect_value(t, w.record.path, "layers")
	testing.expect(t, w.record.ptr == w.ptr, "a plain field's override is the field")
	testing.expect(t, w.owner.handle == comp, "the owner is the component")
	testing.expect_value(t, w.offset, uintptr(offset_of(anim.TimelineAnimator, layers)))
}

// The two addresses: the VALUE is the element's field, the OVERRIDE stops at
// the array, because an override is the whole array.
@(test)
test_property_array_index_keeps_override_on_the_array :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "")
	context.user_ptr = &tc.uc
	defer teardown(tc)

	a, comp := _animator_with_states()
	p, _ := inspector.inspect_comp(comp)

	sp, err := inspector.property(p, "layers[0].states[1].speed")
	testing.expect_value(t, err, inspector.Resolve_Error.None)
	if err != .None do return
	testing.expect(t, sp.ptr == rawptr(&a.layers[0].states[1].speed), "the value is the element's field")
	testing.expect(t, sp.tid == typeid_of(f32))
	testing.expect_value(t, sp.record.path, "layers")
	testing.expect(t, sp.record.ptr == rawptr(&a.layers), "the override names the outer array")
	testing.expect(t, sp.record.tid == typeid_of([dynamic]anim.Animator_Layer))

	// Chaining narrows the same way as one path.
	l, _ := inspector.property(p, "layers[0]")
	sp2, err2 := inspector.property(l, "states[1].speed")
	testing.expect_value(t, err2, inspector.Resolve_Error.None)
	testing.expect(t, sp2.ptr == sp.ptr && sp2.record.ptr == sp.record.ptr, "chained resolution equals the one-shot path")
}

@(test)
test_property_errors_are_reported_not_fatal :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "")
	context.user_ptr = &tc.uc
	defer teardown(tc)

	_, comp := _animator_with_states()
	p, _ := inspector.inspect_comp(comp)

	_, e1 := inspector.property(p, "no_such")
	testing.expect_value(t, e1, inspector.Resolve_Error.No_Such_Field)
	_, e2 := inspector.property(p, "layers[7]")
	testing.expect_value(t, e2, inspector.Resolve_Error.Index_Out_Of_Range)
	_, e3 := inspector.property(p, "layers[0].weight[0]")
	testing.expect_value(t, e3, inspector.Resolve_Error.Not_Indexable)
	_, e4 := inspector.property(p, "layers[0].weight.x")
	testing.expect_value(t, e4, inspector.Resolve_Error.Not_A_Struct)
	_, e5 := inspector.property(p, "layers[x]")
	testing.expect_value(t, e5, inspector.Resolve_Error.Bad_Path)
	_, e6 := inspector.property(p, "layers..states")
	testing.expect_value(t, e6, inspector.Resolve_Error.Bad_Path)

	// A dead handle is not an object.
	_, ok := inspector.inspect_comp(engine.Handle{})
	testing.expect(t, !ok, "a dead handle does not inspect")
}

// A fixed array is an array too: the override stays on it.
@(test)
test_property_fixed_array_index :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "")
	context.user_ptr = &tc.uc
	defer teardown(tc)

	tH := engine.transform_new("T")
	p, ok := inspector.inspect_transform(tH)
	testing.expect(t, ok)
	if !ok do return
	tr := engine.pool_get(&tc.world.transforms, engine.Handle(tH))

	y, err := inspector.property(p, "position[1]")
	testing.expect_value(t, err, inspector.Resolve_Error.None)
	testing.expect(t, y.ptr == rawptr(&tr.position[1]), "element pointer")
	testing.expect(t, y.tid == typeid_of(f32))
	testing.expect_value(t, y.record.path, "position")
	testing.expect(t, y.record.ptr == rawptr(&tr.position), "override names the whole vector")
	testing.expect(t, y.owner.handle == engine.Handle(tH), "the transform owns it")
	testing.expect(t, y.nested_host == {}, "plain content has no prefab context")
}
