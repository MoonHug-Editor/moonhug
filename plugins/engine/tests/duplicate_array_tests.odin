package engine_tests

// Edit/Duplicate Array in its settings panel: a new offset moves the copies
// the run made instead of making them again, and the move is part of the
// run's undo step, so redo brings the copies back where they ended.

import "core:fmt"
import "core:testing"
import "moonhug:editor"
import "moonhug:editor/keymap"
import "moonhug:editor/undo"
import "moonhug:packages/engine"
import "moonhug:packages/engine/editor/scene_views"

// The object of the scene named `name`, {} when there is none.
@(private = "file")
_find_named :: proc(w: ^engine.World, s: ^engine.Scene, name: string) -> engine.Transform_Handle {
	it := engine.pool_iterator(&w.transforms)
	for tr, h in engine.pool_next(&it) {
		if tr.scene != s || tr.name != name do continue
		h := h
		h.type_key = .Transform
		return engine.Transform_Handle(h)
	}
	return {}
}

@(test)
test_duplicate_array_offset_moves_in_place :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	editor.selection_undo_install()
	defer {
		editor.sel_scene_clear()
		editor.sel_proj_clear()
		editor.selection_undo_shutdown()
	}
	defer editor.adjust_last_close()
	defer keymap.command_remove("t.duplicate_array")

	c := keymap.command_add_args("Edit/Duplicate Array", scene_views.edit_duplicate_array, scene_views.Duplicate_Array_Args{count = 3, offset = {1, 0, 0}}, update = scene_views.duplicate_array_update, id = "t.duplicate_array")
	w := engine.ctx_world()
	a := engine.transform_new("A")
	editor.sel_scene_only(a)
	editor.selection_undo_track()

	keymap.command_run(c)
	editor.selection_undo_track()
	testing.expect_value(t, len(s.items), 1)
	copies: [3]engine.Transform_Handle
	for i in 0 ..< 3 {
		copies[i] = _find_named(w, tc.scene, fmt.tprintf("A_%d", i + 1))
		testing.expect(t, copies[i] != {}, "a copy per count")
		testing.expect_value(t, engine.transform_local_position(copies[i]), [3]f32{f32(i + 1), 0, 0})
	}

	// A new offset, twice as on a drag: the same copies move, nothing is made
	// again, and the run stays one undo step.
	args := (^scene_views.Duplicate_Array_Args)(c.args)
	for y in ([]f32{2, 3}) {
		args.offset = {0, y, 0}
		testing.expect(t, editor.adjust_last_apply_edit())
		testing.expect(t, editor.adjust_last_valid())
		testing.expect_value(t, len(s.items), 1)
		for i in 0 ..< 3 {
			testing.expect(t, engine.pool_valid(&w.transforms, engine.Handle(copies[i])), "the copy is the same object")
			testing.expect_value(t, engine.transform_local_position(copies[i]), [3]f32{0, y * f32(i + 1), 0})
		}
	}

	// Undo takes the copies away, redo brings them back where they ended.
	testing.expect(t, undo.apply_undo(s))
	testing.expect(t, _find_named(w, tc.scene, "A_1") == {}, "undo removes the copies")
	testing.expect(t, undo.apply_redo(s))
	for i in 0 ..< 3 {
		h := _find_named(w, tc.scene, fmt.tprintf("A_%d", i + 1))
		testing.expect(t, h != {}, "redo makes the copy again")
		if h != {} do testing.expect_value(t, engine.transform_local_position(h), [3]f32{0, 3 * f32(i + 1), 0})
	}

	// A new count makes the copies again.
	testing.expect(t, undo.apply_undo(s))
	editor.sel_scene_only(a)
	editor.selection_undo_track()
	keymap.command_run(c)
	editor.selection_undo_track()
	first := _find_named(w, tc.scene, "A_1")
	args.count = 2
	testing.expect(t, editor.adjust_last_apply_edit())
	testing.expect(t, !engine.pool_valid(&w.transforms, engine.Handle(first)), "the run was undone and ran again")
	testing.expect(t, _find_named(w, tc.scene, "A_3") == {}, "two copies now")
	testing.expect(t, _find_named(w, tc.scene, "A_2") != {})
}
