package editor

import "core:fmt"
import "core:strings"
import "core:encoding/uuid"
import im "moonhug:external/odin-imgui"
import "menu"
import engine "../engine"
import "undo"

@(private="file")
_history_selected: int = -1

@(private="file")
_history_last_count: int

@(private="file")
_history_split_ratio: f32 = 0.6

draw_history_view :: proc() {
	if !im.Begin("History", &menu.show_history, {.NoCollapse}) {
		im.End()
		return
	}
	defer im.End()

	s := undo.get()
	if s == nil {
		im.TextDisabled("Undo stack unavailable")
		return
	}

	if im.Button("Undo") {
		undo.apply_undo(s)
	}
	im.SameLine()
	if im.Button("Redo") {
		undo.apply_redo(s)
	}
	im.SameLine()
	if im.Button("Clear") {
		undo.clear(s)
		_history_selected = -1
	}

	items := undo.entries(s)
	top := undo.top_index(s)

	im.SameLine()
	im.Text("top=%d  entries=%d", i32(top), i32(len(items)))

	im.Separator()

	avail := im.GetContentRegionAvail()
	splitter_h: f32 = 4
	list_h := (avail.y - splitter_h) * _history_split_ratio
	if list_h < 60 do list_h = 60
	if list_h > avail.y - splitter_h - 60 do list_h = avail.y - splitter_h - 60

	im.BeginChild("HistoryList", im.Vec2{0, list_h}, {.Borders})
	{
		max_index := len(items)

		if im.IsWindowFocused() {
			if im.IsKeyPressed(.UpArrow) {
				if _history_selected > 0 do _history_selected -= 1
				im.SetScrollHereY(0)
			}
			if im.IsKeyPressed(.DownArrow) {
				if _history_selected < max_index do _history_selected += 1
				im.SetScrollHereY(1)
			}
			if im.IsKeyPressed(.Enter) {
				undo.jump_to(s, _history_selected)
			}
		}

		if im.Selectable("<initial>", _history_selected == 0, {.SpanAllColumns}) {
			_history_selected = 0
		}
		if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) {
			undo.jump_to(s, 0)
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

			text_col := im.GetStyleColorVec4(.Text)^
			if is_current {
				text_col = im.Vec4{0.9, 0.8, 0.3, 1}
			} else if step_index > top {
				text_col = im.GetStyleColorVec4(.TextDisabled)^
			}
			im.PushStyleColorImVec4(.Text, text_col)

			if im.Selectable(crow, _history_selected == step_index, {.SpanAllColumns}) {
				_history_selected = step_index
			}
			im.PopStyleColor()

			if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) {
				undo.jump_to(s, step_index)
			}
		}

		if len(items) > _history_last_count {
			im.SetScrollHereY(1)
		}
		_history_last_count = len(items)
	}
	im.EndChild()

	splitter_pos := im.GetCursorScreenPos()
	im.InvisibleButton("##hsplit", im.Vec2{-1, splitter_h})
	if im.IsItemActive() {
		delta := im.GetIO().MouseDelta.y
		total := avail.y - splitter_h
		_history_split_ratio = clamp((list_h + delta) / total, 60 / total, (total - 60) / total)
	}
	if im.IsItemHovered() || im.IsItemActive() {
		im.SetMouseCursor(.ResizeNS)
	}
	dl := im.GetWindowDrawList()
	col := im.IsItemActive() ? im.GetColorU32ImVec4(im.Vec4{0.8, 0.8, 0.8, 0.9}) : im.GetColorU32ImVec4(im.Vec4{0.5, 0.5, 0.5, 0.5})
	im.DrawList_AddLine(dl, splitter_pos, im.Vec2{splitter_pos.x + avail.x, splitter_pos.y}, col, 1)

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
// The details pane, as ONE read-only text field so it can be selected and
// copied — the same treatment the console's detail pane gets, and for the same
// reason: these are values you want to paste into a bug report or diff against
// what you expected.
_draw_history_entry_details :: proc(entry: ^undo.Entry) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "Label: %s\n", entry.label)
	_append_command_details(&b, &entry.cmd, 0)

	text := strings.to_string(b)
	buf := strings.clone_to_cstring(text, context.temp_allocator)
	im.InputTextMultiline("##history_detail_text", buf, uint(len(text) + 1),
		im.Vec2{-1, -1}, {.ReadOnly, .WordWrap})
}

@(private="file")
_append_command_details :: proc(b: ^strings.Builder, cmd: ^undo.Command, depth: int) {
	switch v in cmd {
	case undo.Value_Command:
		_append_value_details(b, v, depth)
	case undo.Structural_Command:
		_append_structural_details(b, v, depth)
	case undo.Group_Command:
		fmt.sbprintf(b, "%sGroup (%d sub-commands)\n", _indent(depth), len(v.subs))
		for i in 0 ..< len(v.subs) {
			sub := v.subs[i]
			_append_command_details(b, &sub, depth + 1)
		}
	case undo.Selection_Command:
		fmt.sbprintf(b, "%sSelection change\n", _indent(depth))
		_append_selection_state(b, "before", v.before, depth + 1)
		_append_selection_state(b, "after", v.after, depth + 1)
	case undo.Dropdown_Revert_Command:
		fmt.sbprintf(b, "%sOverride reverted (%v): %q\n",
			_indent(depth), v.kind, v.property_path)
	case undo.Record_Override_Command:
		fmt.sbprintf(b, "%sPrefab override created: lid %v %q\n",
			_indent(depth), v.target_lid, v.property_path)
	}
}

@(private="file")
_append_selection_state :: proc(b: ^strings.Builder, name: string, st: undo.Selection_State, depth: int) {
	indent := _indent(depth)
	fmt.sbprintf(b, "%s%s: %d scene, %d project\n", indent, name, len(st.scene), len(st.proj))
	for it in st.scene {
		resolved := "unresolved"
		if sc := undo.resolve_scene(it.scene); sc != nil {
			if tH, ok := engine.scene_find_selectable_transform_local_id(sc, it.local_id); ok {
				w := engine.ctx_world()
				if t := engine.pool_get(&w.transforms, engine.Handle(tH)); t != nil do resolved = t.name
			}
		}
		fmt.sbprintf(b, "%s  local_id=%d  %s\n", indent, i64(it.local_id), resolved)
	}
	for r in st.proj {
		path := "(deleted)"
		if p, ok := engine.asset_db_get_path(uuid.Identifier(r.guid)); ok do path = p
		if r.local_id != 0 {
			fmt.sbprintf(b, "%s  %s : sub %d\n", indent, path, i64(r.local_id))
		} else {
			fmt.sbprintf(b, "%s  %s\n", indent, path)
		}
	}
}

@(private="file")
_append_value_details :: proc(b: ^strings.Builder, v: undo.Value_Command, depth: int) {
	indent := _indent(depth)
	fmt.sbprintf(b, "%sValue edit\n", indent)
	_append_target(b, v.target, depth + 1)
	fmt.sbprintf(b, "%s  old: %s\n", indent, _truncate(string(v.old_json), 512))
	fmt.sbprintf(b, "%s  new: %s\n", indent, _truncate(string(v.new_json), 512))
}

@(private="file")
_append_target :: proc(b: ^strings.Builder, t: undo.Property_Target, depth: int) {
	indent := _indent(depth)
	kind_str: string
	switch t.kind {
	case .None:   kind_str = "None"
	case .Pooled: kind_str = t.handle.type_key == .Transform ? "Transform" : "Component"
	case .Raw:    kind_str = "Raw"
	case .Asset:  kind_str = "Asset"
	}
	fmt.sbprintf(b, "%starget: kind=%s local_id=%d handle=%d:%d:%d offset=%d type=%v\n",
		indent, kind_str, i64(t.local_id),
		t.handle.index, t.handle.generation, t.handle.type_key,
		t.offset, t.type_id)

	w := engine.ctx_world()
	resolved := "unresolved"
	if w != nil {
		switch t.kind {
		case .None:
		case .Raw:
			if t.raw_ptr != nil do resolved = "raw"
		case .Asset:
			if path, ok := engine.asset_db_get_path(uuid.Identifier(t.asset_guid)); ok {
				resolved = path
			}
		case .Pooled:
			// resolve_pooled_base falls back to a scene local_id scan, so
			// entries stay resolvable after undo/redo recreated the object
			// under a fresh handle.
			if base, h, ok := undo.resolve_pooled_base(t); ok {
				if h.type_key == .Transform {
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
	fmt.sbprintf(b, "%s  resolved: %s\n", indent, resolved)
}

@(private="file")
_append_structural_details :: proc(b: ^strings.Builder, sc: undo.Structural_Command, depth: int) {
	indent := _indent(depth)
	switch v in sc {
	case undo.Reparent_Command:
		fmt.sbprintf(b, "%sReparent: node=%d  old_parent=%d -> new_parent=%d  (idx %d -> %d)" + "\n",
			indent,
			i64(v.node_local_id),
			i64(v.old_parent_local_id),
			i64(v.new_parent_local_id),
			v.old_index,
			v.new_index)
	case undo.Create_Subtree_Command:
		fmt.sbprintf(b, "%sCreate: parent=%d  root=%d  idx=%d  payload=%d bytes" + "\n",
			indent,
			i64(v.parent_local_id),
			i64(v.root_local_id),
			v.sibling_index,
			len(v.payload))
	case undo.Delete_Subtree_Command:
		fmt.sbprintf(b, "%sDelete: parent=%d  root=%d  idx=%d  payload=%d bytes" + "\n",
			indent,
			i64(v.parent_local_id),
			i64(v.root_local_id),
			v.sibling_index,
			len(v.payload))
	case undo.Add_Component_Command:
		fmt.sbprintf(b, "%sAdd Component: owner=%d  type=%v  comp_local_id=%d  idx=%d  payload=%d bytes" + "\n",
			indent,
			i64(v.owner_local_id),
			v.type_key,
			i64(v.comp_local_id),
			v.list_index,
			len(v.payload))
	case undo.Remove_Component_Command:
		fmt.sbprintf(b, "%sRemove Component: owner=%d  type=%v  comp_local_id=%d  idx=%d  payload=%d bytes" + "\n",
			indent,
			i64(v.owner_local_id),
			v.type_key,
			i64(v.comp_local_id),
			v.list_index,
			len(v.payload))
	case undo.Reorder_Components_Command:
		fmt.sbprintf(b, "%sReorder Components: owner=%d  %d -> %d" + "\n",
			indent,
			i64(v.owner_local_id),
			v.old_index,
			v.new_index)
	case undo.Remove_Unknown_Component_Command:
		fmt.sbprintf(b, "%sRemove Missing Component: owner=%d  comp_local_id=%d  idx=%d  payload=%d bytes" + "\n",
			indent,
			i64(v.owner_local_id),
			i64(v.comp_local_id),
			v.list_index,
			len(v.payload))
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
