package engine_tests

// The pointer package's raycasters (plugins/engine/pointer): an earlier
// order is asked first and hides the ones after it, and among raycasters of
// one order the nearest hit wins. The events themselves are
// tested where the raycasters are: mhgui's and physics3d's tests.

import "core:testing"
import "moonhug:packages/engine"
import pointer "moonhug:packages/engine/pointer"
import common "moonhug:tests/common"

@(private = "file") _front, _near, _far: engine.Transform_Handle
@(private = "file") _front_hits: bool

@(private = "file")
_cast_front :: proc(position: [2]f32, viewport: [2]f32) -> (pointer.Pointer_Hit, bool) {
	return {node = _front, source = .UI}, _front_hits
}

@(private = "file")
_cast_near :: proc(position: [2]f32, viewport: [2]f32) -> (pointer.Pointer_Hit, bool) {
	return {node = _near, source = .World_3D, distance = 2}, true
}

@(private = "file")
_cast_far :: proc(position: [2]f32, viewport: [2]f32) -> (pointer.Pointer_Hit, bool) {
	return {node = _far, source = .World_2D, distance = 9}, true
}

@(test)
test_pointer_raycaster_order :: proc(t: ^testing.T) {
	// A world: other plugins' raycasters are asked too, and they look into it.
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	_front = engine.transform_new("Front")
	_near = engine.transform_new("Near")
	_far = engine.transform_new("Far")
	// Registered lowest first: the order of registration does not matter.
	pointer.raycaster_register(_cast_far)
	pointer.raycaster_register(_cast_near)
	pointer.raycaster_register(_cast_front, pointer.ORDER_UI)
	defer pointer.raycaster_unregister(_cast_far)
	defer pointer.raycaster_unregister(_cast_near)
	defer pointer.raycaster_unregister(_cast_front)

	_front_hits = true
	hit := pointer.hit_at({10, 10}, {800, 600})
	testing.expect(t, hit.node == _front && hit.source == .UI, "the earlier order wins, however near the world's hit is")

	_front_hits = false
	hit = pointer.hit_at({10, 10}, {800, 600})
	testing.expect(t, hit.node == _near && hit.source == .World_3D, "with nothing in front, the nearest of the world's raycasters")
}
