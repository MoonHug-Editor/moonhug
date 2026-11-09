package scene_views

// Edit/Duplicate Array (docs/core/Keymaps.md, "Commands with arguments"): a
// command with arguments, adjusted after it runs in its settings panel. A
// new offset moves the copies in place (duplicate_array_update). A new count
// runs the command again.

import "base:runtime"
import "core:fmt"
import engine "moonhug:packages/engine"
import undo "moonhug:packages/engine/editor/undo"
import "moonhug:editor/session"

// No decor tags: the inspector's generated decorators would import this
// package, which imports the inspector. A count below 1 counts as 1.
Duplicate_Array_Args :: struct {
	count:  int,    // copies of each selected object
	offset: [3]f32, // from one copy to the next, in the parent's space
}

DUPLICATE_ARRAY_DEFAULT :: Duplicate_Array_Args{count = 3, offset = {1, 0, 0}}

// One copy the last run made: where it is offset from and its number.
@(private = "file")
_Copy :: struct {
	copy:  engine.Transform_Handle,
	base:  [3]f32,
	index: int,
}

// What the last run made, for duplicate_array_update. Outlives the frame, so
// it is on the default allocator.
@(private = "file")
_last: struct {
	count:  int,
	copies: [dynamic]_Copy,
}

// Every selected object, the top of a selected subtree, gets `count` copies,
// each `offset` further from the last, named with its number, as one undo
// step. The copies end up selected. Scene roots and objects inside a nested
// scene stay as they are, as Duplicate leaves them.
@(command={name="Edit/Duplicate Array", enabled=duplicate_array_can, defaults=DUPLICATE_ARRAY_DEFAULT, update=duplicate_array_update, help="Duplicates the selection several times, each copy a step further along an offset"})
edit_duplicate_array :: proc(args: ^Duplicate_Array_Args) {
	targets := session.top_level()
	w := engine.ctx_world()
	g := undo.group_begin("Duplicate Array")
	defer undo.group_end(&g)
	undo.record_selection_snapshot()
	count := max(args.count, 1)
	if _last.copies.allocator.procedure == nil {
		_last.copies = make([dynamic]_Copy, runtime.default_allocator())
	}
	clear(&_last.copies)
	_last.count = count
	results := make([dynamic]engine.Transform_Handle, context.temp_allocator)
	for h in targets {
		if !engine.pool_valid(&w.transforms, engine.Handle(h)) do continue
		if _hierarchy_handle_is_root(h) || _hierarchy_handle_is_nested(h) do continue
		base := engine.transform_local_position(h)
		for i in 1 ..= count {
			copy := engine.scene_duplicate_subtree(h)
			if copy == {} do break
			// Moved and named before the create is recorded, so redo makes it
			// where it is.
			engine.transform_set_local_position(copy, base + args.offset * f32(i))
			engine._transform_append_name_suffix(copy, fmt.tprintf("_%d", i))
			if t := engine.pool_get(&w.transforms, engine.Handle(copy)); t != nil {
				undo.record_create(copy, engine.Transform_Handle(t.parent.handle))
			}
			append(&results, copy)
			append(&_last.copies, _Copy{copy = copy, base = base, index = i})
		}
	}
	if len(results) > 0 do undo.group_commit(&g)
	session.select_clear()
	for r in results do session.select_add(r)
}

// Whether Duplicate Array has something to copy, with the reason when not.
duplicate_array_can :: proc() -> bool {
	return _hierarchy_selection_mutable()
}

// Duplicate Array's update: a new offset moves the copies the last run made,
// each one an undo edit of its position. A new count, or a copy that is gone,
// returns false before anything moves, and the command runs again.
duplicate_array_update :: proc(args: ^Duplicate_Array_Args) -> bool {
	if max(args.count, 1) != _last.count do return false
	w := engine.ctx_world()
	for c in _last.copies {
		if !engine.pool_valid(&w.transforms, engine.Handle(c.copy)) do return false
	}
	for c in _last.copies {
		_edit_local_position(c.copy, c.base + args.offset * f32(c.index))
	}
	return true
}

// Sets an object's local position as an undo edit of the field that holds
// it: a UI node's anchored position under a canvas, the transform's position
// otherwise, the two transform_set_local_position writes.
@(private = "file")
_edit_local_position :: proc(tH: engine.Transform_Handle, pos: [3]f32) {
	e: undo.Edit_Scope
	if f, ui := engine.rect_frame(tH); ui {
		rt, _ := engine.transform_get_comp(tH, engine.RectTransform)
		e = undo.edit_begin(rt.handle, &f.rt.anchored_position, typeid_of([3]f32))
	} else {
		t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH))
		if t == nil do return
		e = undo.edit_begin(tH, &t.position, typeid_of([3]f32))
	}
	engine.transform_set_local_position(tH, pos)
	undo.edit_end(&e)
}
