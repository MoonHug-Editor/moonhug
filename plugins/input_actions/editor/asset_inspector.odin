package input_actions_editor

// The Input Actions asset's inspector (docs/InputActions.md): one section
// per map with its name, priority and consume mode, and under it a table
// with a row per binding: the action's name, kind, consumed flag and dead
// zone on the action's first row, then the binding's control, part and
// scale. Buttons add and remove maps, actions and bindings.
//
// Every cell is a field_edit_row over the cell's own value, so a cell edit is
// one undo step of that value. An add or a remove is a structural edit of
// the whole asset.

import "core:fmt"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/icons"
import "moonhug:editor/inspector"
import "moonhug:editor/widgets"
import actions "moonhug:packages/input_actions"

@(provider_install)
_register_asset_inspector :: proc() {
	inspector.add_property_drawer(typeid_of(actions.Input_Actions), draw_input_actions)
}

@(private = "file")
_cell :: proc(ptr: rawptr, $T: typeid, id: cstring, drawer: proc(ptr: rawptr, tid: typeid, label: cstring) = nil) {
	im.SetNextItemWidth(-1)
	d := drawer != nil ? drawer : inspector.resolve_property_drawer(T)
	inspector.field_edit_row(ptr, T, 0, string(id), d, id)
}

draw_input_actions :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	a := cast(^actions.Input_Actions)ptr
	remove_context := -1
	for &m, mi in a.contexts {
		im.PushIDInt(i32(mi))
		defer im.PopID()
		header := fmt.ctprintf("%s##map%d", len(m.name) > 0 ? m.name : "Map", mi)
		im.SetNextItemOpen(true, .Once)
		open := im.CollapsingHeader(header, {.AllowOverlap})
		im.SameLine(im.GetContentRegionAvail().x - 20)
		if im.SmallButton(icons.ICON_MD_CLOSE) do remove_context = mi
		widgets.tooltip("Remove this mapping context")
		if !open do continue

		im.Indent()
		if im.BeginTable("##map_head", 3, im.TableFlags_SizingStretchProp) {
			im.TableSetupColumn("Name", {}, 3)
			im.TableSetupColumn("Priority", {}, 1)
			im.TableSetupColumn("Consume_Input", {}, 1)
			im.TableHeadersRow()
			im.TableNextRow()
			im.TableSetColumnIndex(0)
			_cell(&m.name, string, "##name")
			widgets.tooltip("The context's name, what context_push and action_id name")
			im.TableSetColumnIndex(1)
			_cell(&m.priority, int, "##priority")
			widgets.tooltip("Among the pushed contexts, higher answers first")
			im.TableSetColumnIndex(2)
			_cell(&m.consume, actions.Consume_Input, "##consume", inspector.draw_inspector_enum)
			widgets.tooltip("What the context takes from the contexts below it: every key, or only the keys of its actions marked Consume")
			im.EndTable()
		}

		_draw_actions(&m)

		if im.Button("Add Action") {
			sess := inspector.structural_edit_begin("Add Action")
			append(&m.actions, actions.Action{value_type = .Digital})
			inspector.structural_edit_end(&sess)
		}
		im.Unindent()
		im.Spacing()
	}
	if remove_context >= 0 {
		sess := inspector.structural_edit_begin("Remove Mapping Context")
		_context_free(&a.contexts[remove_context])
		ordered_remove(&a.contexts, remove_context)
		inspector.structural_edit_end(&sess)
	}
	if im.Button("Add Mapping Context") {
		sess := inspector.structural_edit_begin("Add Mapping Context")
		append(&a.contexts, actions.Mapping_Context{consume = .Listed})
		inspector.structural_edit_end(&sess)
	}
}

@(private = "file")
_draw_actions :: proc(m: ^actions.Mapping_Context) {
	if len(m.actions) == 0 do return
	flags := im.TableFlags_SizingStretchProp | im.TableFlags_BordersInnerH | im.TableFlags_RowBg
	if !im.BeginTable("##actions", 8, flags) do return
	defer im.EndTable()
	im.TableSetupColumn("Action", {}, 2)
	im.TableSetupColumn("Value Type", {}, 1.2)
	im.TableSetupColumn("Consume", {.WidthFixed}, 0)
	im.TableSetupColumn("Dead Zone", {}, 1)
	im.TableSetupColumn("Key", {}, 2.2)
	im.TableSetupColumn("Modifier", {}, 1.2)
	im.TableSetupColumn("Scalar", {}, 1)
	im.TableSetupColumn("", {.WidthFixed}, 0)
	im.TableHeadersRow()

	remove_action := -1
	move_from, move_to := -1, -1
	for &ac, ai in m.actions {
		im.PushIDInt(i32(ai))
		defer im.PopID()
		remove_mapping := -1
		// The action's own cells on its first row, one row per mapping, then
		// a row with the add button and the action's delete.
		for &km, r in ac.mappings {
			im.PushIDInt(i32(r))
			defer im.PopID()
			im.TableNextRow()
			if r == 0 do _action_cells(&ac)
			im.TableSetColumnIndex(4)
			_cell(&km.key, actions.Key_Name, "##key", draw_key_name)
			im.TableSetColumnIndex(5)
			_cell(&km.modifier, actions.Modifier, "##modifier", inspector.draw_inspector_enum)
			widgets.tooltip("What the key feeds: the whole value, one side of an Axis1D, one direction of an Axis2D")
			im.TableSetColumnIndex(6)
			_cell(&km.scalar, f32, "##scalar")
			widgets.tooltip("Multiplies the value, 0 reads as 1")
			im.TableSetColumnIndex(7)
			if im.SmallButton(icons.ICON_MD_CLOSE) do remove_mapping = r
			widgets.tooltip("Remove this mapping")
		}
		im.TableNextRow()
		if len(ac.mappings) == 0 do _action_cells(&ac)
		im.TableSetColumnIndex(4)
		if im.SmallButton("+ Mapping") {
			sess := inspector.structural_edit_begin("Add Mapping")
			append(&ac.mappings, actions.Key_Mapping{scalar = 1})
			inspector.structural_edit_end(&sess)
		}
		widgets.tooltip("Add a key mapping to this action")
		im.TableSetColumnIndex(7)
		im.BeginDisabled(ai == 0)
		if im.SmallButton(icons.ICON_MD_EXPAND_LESS) { move_from, move_to = ai, ai - 1 }
		im.EndDisabled()
		widgets.tooltip("Move this action up", im.HoveredFlags_AllowWhenDisabled)
		im.SameLine(0, 2)
		im.BeginDisabled(ai == len(m.actions) - 1)
		if im.SmallButton(icons.ICON_MD_EXPAND_MORE) { move_from, move_to = ai, ai + 1 }
		im.EndDisabled()
		widgets.tooltip("Move this action down", im.HoveredFlags_AllowWhenDisabled)
		im.SameLine(0, 2)
		if im.SmallButton(icons.ICON_MD_DELETE) do remove_action = ai
		widgets.tooltip("Remove this action")

		if remove_mapping >= 0 {
			sess := inspector.structural_edit_begin("Remove Mapping")
			delete(string(ac.mappings[remove_mapping].key))
			ordered_remove(&ac.mappings, remove_mapping)
			inspector.structural_edit_end(&sess)
		}
	}
	if move_from >= 0 {
		sess := inspector.structural_edit_begin("Move Action")
		m.actions[move_from], m.actions[move_to] = m.actions[move_to], m.actions[move_from]
		inspector.structural_edit_end(&sess)
	}
	if remove_action >= 0 {
		sess := inspector.structural_edit_begin("Remove Action")
		_action_free(&m.actions[remove_action])
		ordered_remove(&m.actions, remove_action)
		inspector.structural_edit_end(&sess)
	}
}

@(private = "file")
_action_cells :: proc(ac: ^actions.Action) {
	im.TableSetColumnIndex(0)
	_cell(&ac.name, string, "##action_name")
	widgets.tooltip("The action's name, what action_id names")
	im.TableSetColumnIndex(1)
	_cell(&ac.value_type, actions.Value_Type, "##value_type", inspector.draw_inspector_enum)
	widgets.tooltip("Digital: down, pressed, released. Axis1D: one value. Axis2D: two values")
	im.TableSetColumnIndex(2)
	_cell(&ac.consume_input, bool, "##consume")
	widgets.tooltip("With the context's Consume Input = Listed: the contexts below do not see this action's keys")
	im.TableSetColumnIndex(3)
	_cell(&ac.dead_zone, f32, "##dead_zone")
	widgets.tooltip("Below it the value reads as zero. Radial for Axis2D")
}

@(private = "file")
_action_free :: proc(ac: ^actions.Action) {
	delete(ac.name)
	for &b in ac.mappings do delete(string(b.key))
	delete(ac.mappings)
}

@(private = "file")
_context_free :: proc(m: ^actions.Mapping_Context) {
	delete(m.name)
	for &ac in m.actions do _action_free(&ac)
	delete(m.actions)
}
