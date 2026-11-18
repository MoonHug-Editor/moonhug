package scene_windows

// Render layers to children: after the Inspector's Render Layers row changes
// on an object with children, a dialog asks whether the children take the
// same layers. Yes writes every descendant, in the undo step of the change.

import "base:runtime"
import "core:fmt"
import engine "moonhug:packages/engine"
import "moonhug:editor/icons"
import "moonhug:editor/inspector"
import "moonhug:editor/widgets"
import undo "moonhug:packages/engine/editor/undo"

// The objects the open dialog asks about.
@(private = "file")
_layer_parents: [dynamic]engine.Transform_Handle

// Whether an object under `tH` has other render layers than `tH`.
render_layers_differ_below :: proc(tH: engine.Transform_Handle) -> bool {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return false
	return _differs_below(w, t, t.render_layer)
}

@(private = "file")
_differs_below :: proc(w: ^engine.World, t: ^engine.Transform, layers: u32) -> bool {
	for child in t.children {
		ct := engine.pool_get(&w.transforms, child.handle)
		if ct == nil do continue
		if ct.render_layer != layers || _differs_below(w, ct, layers) do return true
	}
	return false
}

// Gives every object under each of `parents` its parent's render layers.
// The writes join the undo step on top of the stack (the change of the
// parent's own layers), and are a step of their own with none there. On a
// prefab instance each written object records an override.
render_layers_apply_to_children :: proc(parents: []engine.Transform_Handle) {
	w := engine.ctx_world()
	Write :: struct {
		tH:     engine.Transform_Handle,
		layers: u32,
	}
	writes := make([dynamic]Write, context.temp_allocator)
	collect :: proc(w: ^engine.World, t: ^engine.Transform, layers: u32, writes: ^[dynamic]Write) {
		for child in t.children {
			ct := engine.pool_get(&w.transforms, child.handle)
			if ct == nil do continue
			if ct.render_layer != layers do append(writes, Write{engine.Transform_Handle(child.handle), layers})
			collect(w, ct, layers, writes)
		}
	}
	for p in parents {
		t := engine.pool_get(&w.transforms, engine.Handle(p))
		if t == nil do continue
		collect(w, t, t.render_layer, &writes)
	}
	if len(writes) == 0 do return

	edits := make([dynamic]undo.Edit_Target, 0, len(writes), context.temp_allocator)
	for wr in writes {
		t := engine.pool_get(&w.transforms, engine.Handle(wr.tH))
		append(&edits, undo.edit_target_transform(wr.tH, &t.render_layer, typeid_of(u32)))
	}
	group := undo.amend_begin("Render Layers To Children")
	defer undo.group_end(&group)
	sess := undo.edit_session_begin(edits[:], "Render Layers To Children")
	for wr in writes {
		engine.pool_get(&w.transforms, engine.Handle(wr.tH)).render_layer = wr.layers
	}
	undo.edit_session_end(&sess)
	for wr in writes {
		t := engine.pool_get(&w.transforms, engine.Handle(wr.tH))
		is_host := engine.scene_find_nested_scene_for_host(t.scene, wr.tH) != nil
		if !t.nested_owned && !is_host do continue
		host := wr.tH if is_host else engine.transform_immediate_nested_host(wr.tH)
		inspector.override_record(host, t.local_id, "render_layer", &t.render_layer, typeid_of(u32))
	}
	undo.group_commit(&group)
	inspector.mark_inspector_changed()
}

// Asks whether the children of `changed` take its new render layers. No
// dialog when none of them has children with other layers.
render_layers_ask_children :: proc(changed: []engine.Transform_Handle) {
	if _layer_parents == nil do _layer_parents = make([dynamic]engine.Transform_Handle, runtime.default_allocator())
	clear(&_layer_parents)
	for tH in changed do if render_layers_differ_below(tH) do append(&_layer_parents, tH)
	if len(_layer_parents) == 0 do return
	what := "this object's children" if len(_layer_parents) == 1 else fmt.tprintf("the children of these %d objects", len(_layer_parents))
	widgets.dialog_open({
		title       = "Change Render Layers",
		description = fmt.tprintf("Set the same render layers on %s as well?", what),
		icon        = icons.ICON_MD_LAYERS,
		buttons     = {
			{label = "Yes, change children", action = _layer_children_confirmed, is_default = true},
			{label = "No, this object only", is_cancel = true},
		},
	})
}

@(private = "file")
_layer_children_confirmed :: proc() {
	render_layers_apply_to_children(_layer_parents[:])
	clear(&_layer_parents)
}
