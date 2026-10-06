package tests_common

// setup + an installed undo stack, for tests that record undo steps. Set
// context.user_ptr = &tc.uc in the test body afterwards, like after setup.

import "moonhug:packages/engine"
import "moonhug:editor/undo"

@(private)
_undo_pointer_types_registered: bool

setup_undo :: proc(tc: ^TestCtx) -> ^undo.Undo_Stack {
	setup(tc, "")
	context.user_ptr = &tc.uc
	if !_undo_pointer_types_registered {
		engine.register_pointer_type(bool)
		engine.register_pointer_type(int)
		engine.register_pointer_type(i32)
		engine.register_pointer_type(u32)
		engine.register_pointer_type(f32)
		engine.register_pointer_type(string)
		engine.register_pointer_type(engine.Ref)
		_undo_pointer_types_registered = true
	}

	s := new(undo.Undo_Stack)
	undo.init(s)
	undo.install(s)
	return s
}

teardown_undo :: proc(tc: ^TestCtx, s: ^undo.Undo_Stack) {
	undo.destroy(s)
	free(s)
	teardown(tc)
}

// The first transform named `name` in scene `s` (nested_owned: inside a
// nested scene instance), {} when there is none.
find_transform_named :: proc(w: ^engine.World, s: ^engine.Scene, name: string, nested_owned: bool) -> engine.Transform_Handle {
	it := engine.pool_iterator(&w.transforms)
	for tr, h in engine.pool_next(&it) {
		if tr.scene != s || tr.nested_owned != nested_owned do continue
		if tr.name != name do continue
		th := h
		th.type_key = .Transform
		return engine.Transform_Handle(th)
	}
	return {}
}
