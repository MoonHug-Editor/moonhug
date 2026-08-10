package app_tests

// The Tween Graph panel's undo mechanism: an edit to a field INSIDE
// Player.animations, made under a Player-component owner, is one undo step
// that reverts.
//
// The panel shipped without pushing an owner, and the inspector's rows open no
// session with the owner stack empty -- the edit wrote memory and recorded
// NOTHING. The panel itself needs imgui to draw, so what is pinned here is the
// mechanism it relies on: owner pushed, field in the array's heap storage,
// whole-Player granularity (the tween is outside the component's own bytes, so
// the out-of-storage rule applies).

import app ".."
import inspector "moonhug:editor/inspector"
import undo "moonhug:editor/undo"
import "moonhug:engine"
import common "moonhug:tests/common"
import "core:testing"

@(test)
test_tween_field_edit_records_undo_under_player_owner :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	engine.tween_init()

	s := new(undo.Undo_Stack)
	undo.init(s)
	undo.install(s)
	defer { undo.destroy(s); free(s) }

	owner := engine.transform_new("Player")
	_, p_ptr := engine.transform_add_comp(owner, .Player)
	if p_ptr == nil do return
	p := cast(^app.Player)p_ptr
	if p.animations == nil do p.animations = make([dynamic]engine.TweenUnion)
	append(&p.animations, engine.TweenMoveToLocal{position = {5, 0, 0}, duration = 0.5})

	// The Player's component handle -- what the panel pushes.
	comp_handle: engine.Handle
	{
		w := engine.ctx_world()
		tr := engine.pool_get(&w.transforms, engine.Handle(owner))
		for c in tr.components {
			if c.handle.type_key == .Player do comp_handle = c.handle
		}
	}
	testing.expect(t, comp_handle.type_key == .Player, "Player component handle found")

	// The panel's exact flow: owner pushed, then a session over a field inside
	// the tween -- which lives in the animations array's own allocation.
	mv := &p.animations[0].(engine.TweenMoveToLocal)
	undo.push_component_owner(comp_handle)
	before := s.top
	inspector.field_edit_begin(&mv.duration, typeid_of(f32), 0, "duration")
	mv.duration = 2.0
	inspector.field_edit_end()
	undo.pop_owner()

	testing.expect_value(t, s.top, before + 1)

	// Undo rebuilds the whole Player payload, so the array reallocates -- read
	// the tween back through the component, never the old pointer.
	testing.expect(t, undo.apply_undo(s), "undo applies")
	restored := &p.animations[0].(engine.TweenMoveToLocal)
	testing.expect_value(t, restored.duration, f32(0.5))
}
