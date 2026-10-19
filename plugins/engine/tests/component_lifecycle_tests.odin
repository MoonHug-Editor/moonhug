package engine_tests

// The game's lifecycle hooks (component_lifecycle.odin): @(comp_awake),
// @(comp_on_enable), @(comp_on_disable) and @(comp_on_destroy) run only while
// the game runs in the game world, awake walks an object's components then
// its children in two passes (awake, then on_enable), a creation batch awakes
// once at its end, the enable hooks follow the setters and the undo stack, and
// transform_destroy_later destroys at the end of the frame tick.
//
// No test component declares the hooks, so the tests install recorder procs
// for MeshFilter and MeshRenderer into the engine's tables. The lock keeps the
// tests of this file from sharing the tables, and the recorders only record
// on the thread that installed them, so other tests running in parallel are
// unaffected.

import "core:fmt"
import "core:sync"
import "core:testing"
import "moonhug:editor/undo"
import "moonhug:packages/engine"

@(private = "file") _lock: sync.Mutex

@(private = "file", thread_local) _recording: bool
@(private = "file", thread_local) _log: [32]string
@(private = "file", thread_local) _log_n: int
// Makes MeshFilter's awake add a MeshRenderer to its object.
@(private = "file", thread_local) _add_in_awake: bool
// Makes MeshFilter's comp_on_destroy queue this object for destroy.
@(private = "file", thread_local) _queue_on_destroy: engine.Transform_Handle

@(private = "file")
_rec :: proc(kind: string, key: engine.TypeKey, ptr: rawptr) {
	base := cast(^engine.CompData)ptr
	t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(base.owner))
	name := t != nil ? t.name : "?"
	if _log_n < len(_log) {
		_log[_log_n] = fmt.tprintf("%s %s:%v", kind, name, key)
		_log_n += 1
	}
}

@(private = "file")
_awake_mf :: proc(ptr: rawptr) {
	if !_recording do return
	_rec("awake", .MeshFilter, ptr)
	if _add_in_awake do engine.transform_add_comp((cast(^engine.CompData)ptr).owner, .MeshRenderer)
}

@(private = "file")
_awake_mr :: proc(ptr: rawptr) {
	if _recording do _rec("awake", .MeshRenderer, ptr)
}

@(private = "file")
_destroy_mf :: proc(ptr: rawptr) {
	if !_recording do return
	_rec("destroy", .MeshFilter, ptr)
	if _queue_on_destroy != {} {
		engine.transform_destroy_later(_queue_on_destroy)
		_queue_on_destroy = {}
	}
}

@(private = "file")
_destroy_mr :: proc(ptr: rawptr) {
	if _recording do _rec("destroy", .MeshRenderer, ptr)
}

@(private = "file")
_enable_mf :: proc(ptr: rawptr) {
	if _recording do _rec("enable", .MeshFilter, ptr)
}

@(private = "file")
_enable_mr :: proc(ptr: rawptr) {
	if _recording do _rec("enable", .MeshRenderer, ptr)
}

@(private = "file")
_disable_mf :: proc(ptr: rawptr) {
	if _recording do _rec("disable", .MeshFilter, ptr)
}

@(private = "file")
_disable_mr :: proc(ptr: rawptr) {
	if _recording do _rec("disable", .MeshRenderer, ptr)
}

@(private = "file")
_collision_mf :: proc(ptr: rawptr, other: engine.Transform_Handle) {
	if !_recording do return
	ot := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(other))
	_rec(fmt.tprintf("collision_enter other=%s", ot != nil ? ot.name : "?"), .MeshFilter, ptr)
}

@(private = "file")
_begin :: proc() {
	sync.mutex_lock(&_lock)
	engine.component_on_collision_enter_procs[.MeshFilter] = _collision_mf
	engine.component_physics_hooked[.MeshFilter] = true
	engine.component_awake_procs[.MeshFilter] = _awake_mf
	engine.component_awake_procs[.MeshRenderer] = _awake_mr
	engine.component_on_destroy_procs[.MeshFilter] = _destroy_mf
	engine.component_on_destroy_procs[.MeshRenderer] = _destroy_mr
	engine.component_on_enable_procs[.MeshFilter] = _enable_mf
	engine.component_on_enable_procs[.MeshRenderer] = _enable_mr
	engine.component_on_disable_procs[.MeshFilter] = _disable_mf
	engine.component_on_disable_procs[.MeshRenderer] = _disable_mr
	_recording = true
	_log_n = 0
	_add_in_awake = false
	_queue_on_destroy = {}
}

@(private = "file")
_end :: proc() {
	_recording = false
	engine.component_awake_procs[.MeshFilter] = nil
	engine.component_awake_procs[.MeshRenderer] = nil
	engine.component_on_destroy_procs[.MeshFilter] = nil
	engine.component_on_destroy_procs[.MeshRenderer] = nil
	engine.component_on_enable_procs[.MeshFilter] = nil
	engine.component_on_enable_procs[.MeshRenderer] = nil
	engine.component_on_disable_procs[.MeshFilter] = nil
	engine.component_on_disable_procs[.MeshRenderer] = nil
	engine.component_on_collision_enter_procs[.MeshFilter] = nil
	engine.component_physics_hooked[.MeshFilter] = false
	sync.mutex_unlock(&_lock)
}

@(private = "file")
_expect_log :: proc(t: ^testing.T, want: []string, loc := #caller_location) {
	testing.expect_value(t, _log_n, len(want), loc)
	for w, i in want {
		if i < _log_n do testing.expect_value(t, _log[i], w, loc)
	}
	_log_n = 0
}

@(private = "file")
_obj :: proc(name: string, parent: engine.Transform_Handle, keys: ..engine.TypeKey) -> engine.Transform_Handle {
	tH := engine.transform_new(name, parent)
	for k in keys do engine.transform_add_comp(tH, k)
	return tH
}

@(private = "file")
_alive :: proc(tc: ^TestCtx, tH: engine.Transform_Handle) -> bool {
	return engine.pool_get(&tc.world.transforms, engine.Handle(tH)) != nil
}

// Play start awakes the loaded scene, and a paste while the game runs awakes
// the copy: each object's components in list order, then its children.
@(test)
test_awake_order_on_play_and_paste :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	_begin()
	defer _end()

	root := engine.Transform_Handle(tc.scene.root.handle)
	a := _obj("A", root, .MeshFilter, .MeshRenderer)
	b := _obj("B", a, .MeshFilter)
	_obj("C", b, .MeshRenderer)
	_obj("D", a, .MeshRenderer)
	_expect_log(t, {})

	// Two passes: every awake, then every on_enable, in the same order.
	order := []string{
		"awake A:MeshFilter", "awake A:MeshRenderer", "awake B:MeshFilter", "awake C:MeshRenderer", "awake D:MeshRenderer",
		"enable A:MeshFilter", "enable A:MeshRenderer", "enable B:MeshFilter", "enable C:MeshRenderer", "enable D:MeshRenderer",
	}
	engine.application_set_playing(true)
	defer engine.application_set_playing(false)
	_expect_log(t, order)

	data := engine.scene_copy_subtree(a)
	defer delete(data)
	testing.expect(t, engine.scene_paste_subtree(data, root) != {}, "the paste creates the copy")
	_expect_log(t, order)
}

// An add awakes on its own while the game runs. Inside a batch nothing awakes
// until the batch ends.
@(test)
test_awake_on_add_and_batch :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	_begin()
	defer _end()

	root := engine.Transform_Handle(tc.scene.root.handle)
	a := _obj("A", root, .MeshFilter)
	_expect_log(t, {})

	engine.application_set_playing(true)
	defer engine.application_set_playing(false)
	_expect_log(t, {"awake A:MeshFilter", "enable A:MeshFilter"})

	engine.transform_add_comp(a, .MeshRenderer)
	_expect_log(t, {"awake A:MeshRenderer", "enable A:MeshRenderer"})

	engine.awake_batch_begin()
	b := _obj("B", a, .MeshFilter)
	_obj("C", b, .MeshRenderer)
	_expect_log(t, {})
	engine.awake_batch_end(b)
	_expect_log(t, {"awake B:MeshFilter", "awake C:MeshRenderer", "enable B:MeshFilter", "enable C:MeshRenderer"})
}

// A component an awake proc adds awakes once, on its own: the walk visits only
// what the object had when the walk reached it.
@(test)
test_awake_added_in_awake_runs_once :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	_begin()
	defer _end()

	root := engine.Transform_Handle(tc.scene.root.handle)
	_obj("A", root, .MeshFilter)
	_add_in_awake = true
	engine.application_set_playing(true)
	defer engine.application_set_playing(false)
	_add_in_awake = false
	_expect_log(t, {"awake A:MeshFilter", "awake A:MeshRenderer", "enable A:MeshRenderer", "enable A:MeshFilter"})
}

// The hooks run only in the game world: a preview or thumbnail world swapped
// into the context runs none, while the game plays.
@(test)
test_hooks_skip_other_worlds :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	_begin()
	defer _end()

	root := engine.Transform_Handle(tc.scene.root.handle)
	a := _obj("A", root, .MeshFilter)
	_, ptr := engine.transform_get_comp_key(a, .MeshFilter)
	testing.expect(t, !engine.game_running(), "edit mode is no game")

	engine.application_set_playing(true)
	defer engine.application_set_playing(false)
	testing.expect(t, engine.game_running())
	_expect_log(t, {"awake A:MeshFilter", "enable A:MeshFilter"})

	preview := new(engine.World)
	defer free(preview)
	engine.w_init(preview)
	defer engine.world_destroy_all(preview)
	tc.uc.world = preview
	testing.expect(t, !engine.game_running(), "a preview world is no game")
	engine.component_awake(.MeshFilter, ptr)
	engine.awake_subtree(a)
	tc.uc.world = &tc.world
	_expect_log(t, {})
}

// comp_on_destroy runs only while the game runs: a destroy in edit mode runs
// none, Stop runs it on every live component once.
@(test)
test_on_destroy_only_while_playing :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	_begin()
	defer _end()

	root := engine.Transform_Handle(tc.scene.root.handle)
	a := _obj("A", root, .MeshFilter)
	b := _obj("B", root, .MeshRenderer)
	engine.transform_destroy(a)
	_expect_log(t, {})

	engine.application_set_playing(true)
	_expect_log(t, {"awake B:MeshRenderer", "enable B:MeshRenderer"})
	engine.transform_destroy(b)
	_expect_log(t, {"disable B:MeshRenderer", "destroy B:MeshRenderer"})

	c := _obj("C", root, .MeshFilter)
	_expect_log(t, {"awake C:MeshFilter", "enable C:MeshFilter"})
	engine.application_set_playing(false)
	_expect_log(t, {"disable C:MeshFilter", "destroy C:MeshFilter"})

	engine.transform_destroy(c)
	_expect_log(t, {})
}

// transform_destroy_later destroys at the end of the frame tick, once per
// object, and an object queued by a comp_on_destroy proc goes in the same
// pass.
@(test)
test_destroy_later_at_frame_end :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	engine.fixed_reset()
	defer engine.fixed_reset()
	_begin()
	defer _end()

	engine.application_set_playing(true)
	defer engine.application_set_playing(false)
	root := engine.Transform_Handle(tc.scene.root.handle)
	a := _obj("A", root, .MeshFilter)
	b := _obj("B", root, .MeshRenderer)
	_log_n = 0

	_queue_on_destroy = b
	engine.transform_destroy_later(a)
	engine.transform_destroy_later(a)
	testing.expect(t, _alive(tc, a), "a queued object lives until the frame tick ends")
	_expect_log(t, {})

	engine.frame_tick({}, 0)
	_expect_log(t, {"disable A:MeshFilter", "destroy A:MeshFilter", "disable B:MeshRenderer", "destroy B:MeshRenderer"})
	testing.expect(t, !_alive(tc, a), "the queued object is gone")
	testing.expect(t, !_alive(tc, b), "the object queued while the queue ran is gone too")
}

// Stop drops the queue: an object that stays loses its mark and can be queued
// again.
@(test)
test_stop_drops_destroy_queue :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)

	root := engine.Transform_Handle(tc.scene.root.handle)
	a := _obj("A", root)
	engine.application_set_playing(true)
	engine.transform_destroy_later(a)
	engine.application_set_playing(false)
	engine.transform_destroy_pending()
	testing.expect(t, _alive(tc, a), "Stop destroys nothing it dropped")

	engine.transform_destroy_later(a)
	engine.transform_destroy_pending()
	testing.expect(t, !_alive(tc, a), "the dropped object queues again")
}

// The enable hooks follow the effective state: an inactive object's
// components awake without on_enable, the setters fire at once for the whole
// subtree, and a disabled component gets no on_enable from an active parent.
@(test)
test_enable_follows_setters :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	_begin()
	defer _end()

	root := engine.Transform_Handle(tc.scene.root.handle)
	a := _obj("A", root, .MeshFilter)
	b := _obj("B", a, .MeshRenderer)
	if bt := engine.pool_get(&tc.world.transforms, engine.Handle(b)); bt != nil do bt.is_active = false

	engine.application_set_playing(true)
	defer engine.application_set_playing(false)
	_expect_log(t, {"awake A:MeshFilter", "awake B:MeshRenderer", "enable A:MeshFilter"})
	engine.enabled_verify()

	engine.transform_set_active(b, true)
	_expect_log(t, {"enable B:MeshRenderer"})
	engine.transform_set_active(b, true)
	_expect_log(t, {})

	_, mr := engine.transform_get_comp_key(b, .MeshRenderer)
	engine.comp_set_enabled(cast(^engine.CompData)mr, false)
	_expect_log(t, {"disable B:MeshRenderer"})

	engine.transform_set_active(a, false)
	_expect_log(t, {"disable A:MeshFilter"})
	engine.transform_set_active(a, true)
	_expect_log(t, {"enable A:MeshFilter"})
	engine.comp_set_enabled(cast(^engine.CompData)mr, true)
	_expect_log(t, {"enable B:MeshRenderer"})
	engine.enabled_verify()
}

// An editor write of the active flag reaches the hooks through the undo stack:
// the edit session syncs after the gesture, and undo syncs after its write.
@(test)
test_enable_follows_undo_writes :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	_begin()
	defer _end()

	root := engine.Transform_Handle(tc.scene.root.handle)
	a := _obj("A", root, .MeshFilter)
	engine.application_set_playing(true)
	defer engine.application_set_playing(false)
	_log_n = 0

	at := engine.pool_get(&tc.world.transforms, engine.Handle(a))
	e := undo.edit_begin(a, &at.is_active, typeid_of(bool), "Toggle Active")
	at.is_active = false
	_expect_log(t, {})
	undo.edit_end(&e)
	_expect_log(t, {"disable A:MeshFilter"})
	engine.enabled_verify()

	testing.expect(t, undo.apply_undo(s), "the toggle undoes")
	_expect_log(t, {"enable A:MeshFilter"})
	testing.expect(t, undo.apply_redo(s), "the toggle redoes")
	_expect_log(t, {"disable A:MeshFilter"})
	engine.enabled_verify()
}

// A contact event runs the hooks of the shape owners' own components, both
// ways. An object with no hooked component is skipped by its bit, and the
// bit clears once its hooked components are gone.
@(test)
test_physics_contact_hooks :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	_begin()
	defer _end()

	root := engine.Transform_Handle(tc.scene.root.handle)
	a := _obj("A", root, .MeshFilter)
	b := _obj("B", root, .MeshRenderer)
	engine.physics_contact_dispatch(.Collision_Enter, a, b)
	_expect_log(t, {})

	engine.application_set_playing(true)
	defer engine.application_set_playing(false)
	_log_n = 0
	at := engine.pool_get(&tc.world.transforms, engine.Handle(a))
	bt := engine.pool_get(&tc.world.transforms, engine.Handle(b))
	testing.expect(t, at.physics_hooked, "awake marks the object with a hooked component")
	testing.expect(t, !bt.physics_hooked, "an object without one stays unmarked")

	engine.physics_contact_dispatch(.Collision_Enter, b, a)
	_expect_log(t, {"collision_enter other=B A:MeshFilter"})

	owned, _ := engine.transform_get_comp_key(a, .MeshFilter)
	engine.transform_remove_comp(a, owned.handle)
	_expect_log(t, {"disable A:MeshFilter", "destroy A:MeshFilter"})
	engine.physics_contact_dispatch(.Collision_Enter, a, b)
	_expect_log(t, {})
	testing.expect(t, !at.physics_hooked, "a dispatch that finds no hook clears the mark")
}
