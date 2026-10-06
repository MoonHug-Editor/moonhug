package scene_tools

// The context @(on_draw_gizmos) and @(on_scene_handles) procs get for each
// instance (the generated dispatchers call gizmo_context): its selection state
// and the scene view's tool.
//
// The dispatchers ask for every instance with a hook, every frame, so the
// answer is a lookup. gizmo_marks_rebuild, which the gizmo pass calls right
// before the hooks, marks the selected transforms and walks down their
// subtrees once: its cost is the size of the selected subtrees, not the whole
// scene. One mark per transform pool slot (the pool has engine.MAX slots and a
// handle carries its slot index), stamped per rebuild so the array never needs
// clearing, with the generation it was written for so a reused slot never
// inherits a mark.

import "moonhug:editor/handles"
import "moonhug:editor/viewport"
import "moonhug:packages/engine"

@(private = "file")
_Gizmo_Mark :: struct {
	stamp:      u32,
	generation: u16,
	state:      bit_set[handles.Gizmo_State],
}

@(private = "file")
_marks: [engine.MAX]_Gizmo_Mark

@(private = "file")
_stamp: u32

// Marks the current selection: each selected transform is Selected (the active
// one Active too) and In_Selection, every descendant In_Selection. Call before
// asking gizmo_context (the gizmo pass does, right before the hooks).
gizmo_marks_rebuild :: proc() {
	_stamp += 1
	w := engine.ctx_world()
	if w == nil do return
	stack := make([dynamic]engine.Transform_Handle, context.temp_allocator)
	for tH in viewport.selection() {
		// Already In_Selection: an earlier selected root's walk reached it (a
		// child selected along with its parent), so its subtree is marked.
		walked := .In_Selection in _mark_of(tH)
		_mark(tH, {.Selected})
		if walked do continue
		append(&stack, tH)
		for len(stack) > 0 {
			h := pop(&stack)
			t := engine.pool_get(&w.transforms, engine.Handle(h))
			if t == nil do continue
			for child in t.children {
				ch := engine.Transform_Handle(child.handle)
				if .In_Selection in _mark_of(ch) do continue // walked from an earlier selected root
				_mark(ch, {.In_Selection})
				append(&stack, ch)
			}
		}
	}
	if active := viewport.active(); active != {} do _mark(active, {.Active})
}

gizmo_context :: proc(tH: engine.Transform_Handle) -> handles.Gizmo_Context {
	return handles.Gizmo_Context{state = _mark_of(tH), tool = viewport.gizmo_mode}
}

@(private = "file")
_mark_of :: proc(tH: engine.Transform_Handle) -> bit_set[handles.Gizmo_State] {
	i := engine.Handle(tH).index
	if int(i) >= len(_marks) do return {}
	m := _marks[i]
	if m.stamp != _stamp || m.generation != engine.Handle(tH).generation do return {}
	return m.state
}

@(private = "file")
_mark :: proc(tH: engine.Transform_Handle, state: bit_set[handles.Gizmo_State]) {
	i := engine.Handle(tH).index
	if int(i) >= len(_marks) do return
	m := &_marks[i]
	if m.stamp != _stamp || m.generation != engine.Handle(tH).generation {
		m^ = {stamp = _stamp, generation = engine.Handle(tH).generation}
	}
	m.state += state + {.In_Selection}
}
