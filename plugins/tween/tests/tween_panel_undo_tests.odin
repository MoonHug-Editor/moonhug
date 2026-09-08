package tween_tests

// The Tween Graph panel's undo mechanism: an edit spliced into an authored
// blob under a whole-component session is one undo step that reverts the
// blob. The panel itself needs imgui to draw — what is pinned here is the
// mechanism it relies on.

import "core:encoding/json"
import undo "moonhug:editor/undo"
import "moonhug:engine"
import tween "moonhug:packages/tween"
import common "moonhug:tests/common"
import "core:testing"

@(private)
_duration_of :: proc(a: ^tween.Authored) -> f64 {
	obj, ok := a.value.(json.Object)
	if !ok do return -1
	#partial switch d in obj["duration"] {
	case json.Float:   return f64(d)
	case json.Integer: return f64(d)
	}
	return -1
}

@(test)
test_blob_edit_records_undo_under_component_owner :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()

	s := new(undo.Undo_Stack)
	undo.init(s)
	undo.install(s)
	defer { undo.destroy(s); free(s) }

	owner := engine.transform_new("TweenPlayer")
	_, p_ptr := engine.transform_add_comp(owner, .TweenPlayer)
	if p_ptr == nil do return
	p := cast(^tween.TweenPlayer)p_ptr
	if p.animations == nil do p.animations = make([dynamic]tween.Authored)
	append(&p.animations, tween.authored(tween.TweenMoveToLocal{position = {5, 0, 0}, duration = 0.5}))

	comp_handle: engine.Handle
	{
		w := engine.ctx_world()
		tr := engine.pool_get(&w.transforms, engine.Handle(owner))
		for c in tr.components {
			if c.handle.type_key == .TweenPlayer do comp_handle = c.handle
		}
	}
	testing.expect(t, comp_handle.type_key == .TweenPlayer, "TweenPlayer component handle found")

	// The panel's exact flow: whole-component session around a blob splice.
	before := s.top
	{
		e := undo.edit_begin(comp_handle, typeid_of(tween.TweenPlayer))
		obj := p.animations[0].value.(json.Object)
		if old, has := obj["duration"]; has do json.destroy_value(old)
		obj["duration"] = json.Float(2.0)
		undo.edit_end(&e)
	}
	testing.expect_value(t, s.top, before + 1)
	testing.expect_value(t, _duration_of(&p.animations[0]), 2.0)

	// Undo restores the whole component payload — the blob reverts.
	testing.expect(t, undo.apply_undo(s), "undo applies")
	testing.expect_value(t, _duration_of(&p.animations[0]), 0.5)
}
