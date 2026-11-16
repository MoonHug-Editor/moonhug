package scene_windows

// What a drop on the Hierarchy does (moonhug/editor/drag). The window offers
// a drag to these rules at each place it can land: before or after a row
// (the row's parent, at its index), on a row (as its last child), on the
// empty space below the rows (the scene's root), and on the window's
// background (no parent, beside the loaded scenes).

import "core:encoding/uuid"
import "core:fmt"
import "moonhug:editor/drag"
import "moonhug:editor/session"
import "moonhug:packages/engine"
import "moonhug:packages/engine/editor/scene_tools"
import undo "moonhug:packages/engine/editor/undo"

// Objects dragged within the Hierarchy move under the place's parent, in
// their order, keeping their world transforms. One undo step. An object
// cannot move under itself or its own children, and a scene root stays.
@(drop={what = "object", on = "hierarchy"})
drop_objects_in_hierarchy :: proc(d: ^drag.Drop) -> bool {
	p := d.place.(drag.Hierarchy_Place)
	if !_hierarchy_handle_valid(p.parent) do return false
	moving := make([dynamic]engine.Transform_Handle, context.temp_allocator)
	for h in drag.objects_of(d.items) {
		if h == p.parent || _hierarchy_handle_is_root(h) || _is_ancestor(h, p.parent) do continue
		append(&moving, h)
	}
	if len(moving) == 0 do return false
	if !d.perform {
		parent := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(p.parent))
		d.hint = len(moving) == 1 ? fmt.tprintf("Move %s under %s", _name_of(moving[0]), parent.name) : fmt.tprintf("Move %d objects under %s", len(moving), parent.name)
		return true
	}
	w := engine.ctx_world()
	g := undo.group_begin(len(moving) == 1 ? fmt.tprintf("Move %s", _name_of(moving[0])) : "Move Objects")
	defer undo.group_end(&g)
	index := p.index
	for h in moving {
		at := index
		// An object moving down among its own siblings frees the slot it
		// leaves: the place's index counts it.
		if at >= 0 {
			if t := engine.pool_get(&w.transforms, engine.Handle(h)); t != nil && engine.Transform_Handle(t.parent.handle) == p.parent && engine.transform_get_sibling_index(h) < at {
				at -= 1
			}
		}
		undo.record_reparent_to(h, p.parent, at)
		if index >= 0 do index = engine.transform_get_sibling_index(h) + 1
	}
	undo.group_commit(&g)
	_hierarchy_reveal_open(p.parent)
	return true
}

// Scenes dropped on the window's background open beside the loaded ones.
@(drop={what = "asset:scene", on = "hierarchy"})
drop_scenes_in_hierarchy :: proc(d: ^drag.Drop) -> bool {
	p := d.place.(drag.Hierarchy_Place)
	// On a row or below the rows, a scene is an asset like any other: an
	// instance, by the next rule.
	if p.parent != {} do return false
	refs := drag.assets_of(d.items)
	for ref in refs do if ref.local_id != 0 do return false
	if !d.perform {
		d.hint = len(refs) == 1 ? fmt.tprintf("Open %s beside the loaded scenes", drag.asset_name(refs[0])) : fmt.tprintf("Open %d scenes beside the loaded ones", len(refs))
		return true
	}
	for ref in refs {
		if path, ok := engine.asset_db_get_path(uuid.Identifier(ref.guid)); ok do engine.scene_load(path, additive = true)
	}
	return true
}

// Assets dropped on a row or below the rows become objects under the place's
// parent (scene_tools.asset_drop). One undo step, the objects selected.
@(drop={what = "asset", on = "hierarchy"})
drop_assets_in_hierarchy :: proc(d: ^drag.Drop) -> bool {
	p := d.place.(drag.Hierarchy_Place)
	if !_hierarchy_handle_valid(p.parent) do return false
	refs := drag.assets_of(d.items)
	for ref in refs do if !scene_tools.asset_drop_accepts(ref) do return false
	if !d.perform {
		d.hint = scene_tools.place_hint(refs)
		return true
	}
	scene_tools.place_assets(refs, p.parent, nil, p.index)
	_hierarchy_reveal_open(p.parent)
	return true
}

@(private = "file")
_name_of :: proc(h: engine.Transform_Handle) -> string {
	t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(h))
	return t != nil ? t.name : ""
}

// The drag's items from a Hierarchy row: the selection's top-level objects
// when the row is one of them, else the row's object.
_hierarchy_drag_items :: proc(tH: engine.Transform_Handle) -> []drag.Item {
	out := make([dynamic]drag.Item, context.temp_allocator)
	if session.is_selected(tH) {
		for h in session.top_level() do append(&out, drag.Item(h))
	} else {
		append(&out, drag.Item(tH))
	}
	return out[:]
}
