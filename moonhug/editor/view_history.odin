package editor

import "core:fmt"
import "core:strings"
import im "../../external/odin-imgui"
import engine "../engine"
import undo_pkg "undo"

@(private="file")
_history_selected: int = -1

@(private="file")
_history_last_count: int

draw_history_view :: proc() {
	if !im.Begin("History", nil, {.NoCollapse}) {
		im.End()
		return
	}
	defer im.End()

	s := undo_pkg.get()
	if s == nil {
		im.TextDisabled("Undo stack unavailable")
		return
	}

	if im.Button("Undo") {
		undo_pkg.apply_undo(s)
	}
	im.SameLine()
	if im.Button("Redo") {
		undo_pkg.apply_redo(s)
	}
	im.SameLine()
	if im.Button("Clear") {
		undo_pkg.clear(s)
		_history_selected = -1
	}

	items := undo_pkg.entries(s)
	top := undo_pkg.top_index(s)

	im.SameLine()
	im.Text("top=%d  entries=%d", i32(top), i32(len(items)))

	im.Separator()

	avail := im.GetContentRegionAvail()
	list_h := avail.y * 0.6
	if list_h < 120 do list_h = 120

	im.BeginChild("HistoryList", im.Vec2{0, list_h}, {.Borders})
	{
		if im.Selectable("<initial>", _history_selected == 0, {.SpanAllColumns}) {
			_history_selected = 0
		}
		if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) {
			undo_pkg.jump_to(s, 0)
		}

		for entry, i in items {
			step_index := i + 1
			status: string
			if step_index <= top {
				status = "done"
			} else {
				status = "redo"
			}
			is_current := step_index == top
			label := entry.label
			if label == "" do label = "(unlabeled)"
			row := fmt.tprintf("%s %2d. %s  [%s]", is_current ? ">" : " ", step_index, label, status)
			crow := strings.clone_to_cstring(row, context.temp_allocator)

			if !is_current && step_index > top {
				im.PushStyleColorImVec4(.Text, im.Vec4{0.6, 0.6, 0.6, 1})
			} else if is_current {
				im.PushStyleColorImVec4(.Text, im.Vec4{0.9, 0.8, 0.3, 1})
			} else {
				im.PushStyleColorImVec4(.Text, im.Vec4{1, 1, 1, 1})
			}

			if im.Selectable(crow, _history_selected == step_index, {.SpanAllColumns}) {
				_history_selected = step_index
			}
			im.PopStyleColor()

			if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) {
				undo_pkg.jump_to(s, step_index)
			}
		}

		if len(items) > _history_last_count {
			im.SetScrollHereY(1)
		}
		_history_last_count = len(items)
	}
	im.EndChild()

	im.Separator()
	im.BeginChild("HistoryDetails", im.Vec2{0, 0}, {.Borders})
	defer im.EndChild()

	if _history_selected < 0 {
		im.TextDisabled("Select an entry to see details")
		return
	}
	if _history_selected == 0 {
		im.Text("Initial state")
		im.TextDisabled("Double-click any row to jump to that step.")
		return
	}
	if _history_selected > len(items) {
		_history_selected = -1
		return
	}

	entry := items[_history_selected - 1]
	_draw_history_entry_details(&entry)
}

@(private="file")
_draw_history_entry_details :: proc(entry: ^undo_pkg.Entry) {
	im.Text("Label: %s", cstr(entry.label))
	im.Separator()
	_draw_command_details(&entry.cmd, 0)
}

@(private="file")
_draw_command_details :: proc(cmd: ^undo_pkg.Command, depth: int) {
	switch v in cmd {
	case undo_pkg.Value_Command:
		_draw_value_details(v, depth)
	case undo_pkg.Structural_Command:
		_draw_structural_details(v, depth)
	case undo_pkg.Group_Command:
		im.Text("%sGroup (%d sub-commands)", cstr(_indent(depth)), i32(len(v.subs)))
		for i in 0 ..< len(v.subs) {
			sub := v.subs[i]
			_draw_command_details(&sub, depth + 1)
		}
	}
}

@(private="file")
_draw_value_details :: proc(v: undo_pkg.Value_Command, depth: int) {
	indent := _indent(depth)
	im.Text("%sValue edit", cstr(indent))
	_draw_target(v.target, depth + 1)

	old_s := string(v.old_json)
	new_s := string(v.new_json)
	im.Text("%s  old:", cstr(indent))
	im.SameLine()
	im.TextWrapped(cstr(_truncate(old_s, 512)))
	im.Text("%s  new:", cstr(indent))
	im.SameLine()
	im.TextWrapped(cstr(_truncate(new_s, 512)))
}

@(private="file")
_draw_target :: proc(t: undo_pkg.Property_Target, depth: int) {
	indent := _indent(depth)
	kind_str: string
	switch t.kind {
	case .None:   kind_str = "None"
	case .Pooled: kind_str = t.handle.type_key == .Transform ? "Transform" : "Component"
	case .Raw:    kind_str = "Raw"
	}
	im.Text("%starget: kind=%s local_id=%d handle=%d:%d:%d offset=%d type=%v",
		cstr(indent),
		cstr(kind_str),
		i32(t.local_id),
		i32(t.handle.index),
		i32(t.handle.generation),
		i32(t.handle.type_key),
		i32(t.offset),
		t.type_id)

	w := engine.ctx_world()
	resolved := "unresolved"
	if w != nil {
		switch t.kind {
		case .None:
		case .Raw:
			if t.raw_ptr != nil do resolved = "raw"
		case .Pooled:
			if engine.world_pool_valid(w, t.handle) {
				if base := engine.world_pool_get(w, t.handle); base != nil {
					if t.handle.type_key == .Transform {
						tr := cast(^engine.Transform)base
						resolved = tr.name
					} else {
						c := cast(^engine.CompData)base
						if ot := engine.pool_get(&w.transforms, engine.Handle(c.owner)); ot != nil {
							resolved = ot.name
						}
					}
				}
			}
		}
	}
	im.Text("%s  resolved: %s", cstr(indent), cstr(resolved))
}

@(private="file")
_draw_structural_details :: proc(sc: undo_pkg.Structural_Command, depth: int) {
	indent := _indent(depth)
	switch v in sc {
	case undo_pkg.Reparent_Command:
		im.Text("%sReparent: node=%d  old_parent=%d -> new_parent=%d  (idx %d -> %d)",
			cstr(indent),
			i32(v.node_local_id),
			i32(v.old_parent_local_id),
			i32(v.new_parent_local_id),
			i32(v.old_index),
			i32(v.new_index))
	case undo_pkg.Create_Subtree_Command:
		im.Text("%sCreate: parent=%d  root=%d  idx=%d  payload=%d bytes",
			cstr(indent),
			i32(v.parent_local_id),
			i32(v.root_local_id),
			i32(v.sibling_index),
			i32(len(v.payload)))
	case undo_pkg.Delete_Subtree_Command:
		im.Text("%sDelete: parent=%d  root=%d  idx=%d  payload=%d bytes",
			cstr(indent),
			i32(v.parent_local_id),
			i32(v.root_local_id),
			i32(v.sibling_index),
			i32(len(v.payload)))
	case undo_pkg.Add_Component_Command:
		im.Text("%sAdd Component: owner=%d  type=%v  comp_local_id=%d  idx=%d  payload=%d bytes",
			cstr(indent),
			i32(v.owner_local_id),
			v.type_key,
			i32(v.comp_local_id),
			i32(v.list_index),
			i32(len(v.payload)))
	case undo_pkg.Remove_Component_Command:
		im.Text("%sRemove Component: owner=%d  type=%v  comp_local_id=%d  idx=%d  payload=%d bytes",
			cstr(indent),
			i32(v.owner_local_id),
			v.type_key,
			i32(v.comp_local_id),
			i32(v.list_index),
			i32(len(v.payload)))
	case undo_pkg.Reorder_Components_Command:
		im.Text("%sReorder Components: owner=%d  %d -> %d",
			cstr(indent),
			i32(v.owner_local_id),
			i32(v.old_index),
			i32(v.new_index))
	}
}

@(private="file")
_indent :: proc(depth: int) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for _ in 0 ..< depth {
		strings.write_string(&b, "  ")
	}
	return strings.to_string(b)
}

@(private="file")
_truncate :: proc(s: string, max: int) -> string {
	if len(s) <= max do return s
	return fmt.tprintf("%s ...(%d bytes)", s[:max], len(s))
}

@(private="file")
cstr :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}
