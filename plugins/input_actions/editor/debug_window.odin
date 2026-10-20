package input_actions_editor

// The Input Actions debug window (Window ▸ Input ▸ Input Actions): the pushed
// contexts from the top down, and under each its actions with their live
// frame values and keys. An action whose keys a context above consumes shows
// greyed out: it cannot answer. The values are the game's, so the window
// shows something only while the game runs.

import "core:encoding/uuid"
import "core:fmt"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/widgets"
import "moonhug:editor/window"
import "moonhug:libs/input"
import engine "moonhug:packages/engine"
import actions "moonhug:packages/input_actions"

@(menu_item={path="Window/Input/Input Actions", order=0})
input_actions_window_open :: proc() {
	window.open("input_actions_debug")
}

@(editor_window={id="input_actions_debug", title="Input Actions", icon="SPORTS_ESPORTS", width=620, height=400})
input_actions_window_draw :: proc() {
	im.TextDisabled(engine.application_is_playing() ? "Live values of the running game" : "The values update while the game runs")
	im.SameLine()
	im.TextDisabled(input.gamepad_connected() ? "  gamepad connected" : "  no gamepad")

	// The asset behind the runtime, one click away: the Input setting's.
	guid := actions.input_settings.actions
	if guid == {} {
		im.TextDisabled("No Input Actions asset: pick one in Project Settings > Input")
	} else {
		path, has_path := engine.asset_db_get_path(uuid.Identifier(guid))
		im.TextUnformatted(fmt.ctprintf("Asset: %s", has_path ? path : "(missing)"))
		im.SameLine()
		if im.SmallButton("Select") do engine.inspector_request_select_asset(guid)
		widgets.tooltip("Select the asset in the Project view and the Project Inspector, to edit it. Edits reach the game at once")
	}

	// Every context of the asset with a Push or Pop button: a way to try a
	// stack without the game code that would push it.
	im.SeparatorText("Mapping contexts")
	if im.BeginTable("##contexts", 4, im.TableFlags_SizingStretchProp) {
		im.TableSetupColumn("Context", {}, 2)
		im.TableSetupColumn("Priority", {}, 1)
		im.TableSetupColumn("Consume Input", {}, 1.2)
		im.TableSetupColumn("", {.WidthFixed}, 0)
		im.TableHeadersRow()
		for c in actions.contexts_all() {
			im.PushIDInt(i32(uintptr(raw_data(c.name))))
			im.TableNextRow()
			im.TableSetColumnIndex(0)
			if c.pushed {
				im.TextColored({0.7, 0.7, 1, 1}, fmt.ctprintf("%s", c.name))
			} else {
				im.TextDisabled(fmt.ctprintf("%s", c.name))
			}
			im.TableSetColumnIndex(1)
			im.TextUnformatted(fmt.ctprintf("%d", c.priority))
			im.TableSetColumnIndex(2)
			im.TextUnformatted(fmt.ctprintf("%v", c.consume))
			im.TableSetColumnIndex(3)
			if c.pushed {
				if im.SmallButton("Pop") do actions.context_pop(c.name)
				widgets.tooltip("Pop this context: its actions read as released and zero")
			} else {
				if im.SmallButton("Push") do actions.context_push(c.name)
				widgets.tooltip("Push this context: it answers above the lower-priority ones")
			}
			im.PopID()
		}
		im.EndTable()
	}

	im.SeparatorText("Actions")
	rows := actions.debug_rows()
	if len(rows) == 0 {
		im.TextDisabled("No mapping context is pushed")
		return
	}
	flags := im.TableFlags_SizingStretchProp | im.TableFlags_BordersInnerH | im.TableFlags_RowBg
	if !im.BeginTable("##input_debug", 5, flags) do return
	defer im.EndTable()
	im.TableSetupColumn("Action", {}, 1.6)
	im.TableSetupColumn("State", {}, 1)
	im.TableSetupColumn("Value", {}, 1)
	im.TableSetupColumn("Keys", {}, 2.5)
	im.TableSetupColumn("", {.WidthFixed}, 0)
	im.TableHeadersRow()
	last := ""
	for r in rows {
		if r.context_name != last {
			last = r.context_name
			im.TableNextRow()
			im.TableSetColumnIndex(0)
			im.TextColored({0.7, 0.7, 1, 1}, fmt.ctprintf("%s", r.context_name))
			widgets.tooltip("A pushed mapping context, higher answers first")
		}
		im.TableNextRow()
		if r.blocked do im.PushStyleColorImVec4(.Text, im.GetStyleColorVec4(.TextDisabled)^)
		im.TableSetColumnIndex(0)
		im.TextUnformatted(fmt.ctprintf("    %s", r.action))
		if r.blocked do widgets.tooltip("Every key of this action is consumed by a context above")
		im.TableSetColumnIndex(1)
		state := r.pressed ? "pressed" : r.released ? "released" : r.down ? "down" : "-"
		im.TextUnformatted(fmt.ctprintf("%s", state))
		im.TableSetColumnIndex(2)
		switch r.value_type {
		case .Digital: im.TextUnformatted(r.down ? "1" : "0")
		case .Axis1D:  im.TextUnformatted(fmt.ctprintf("%.2f", r.value.x))
		case .Axis2D:  im.TextUnformatted(fmt.ctprintf("%.2f, %.2f", r.value.x, r.value.y))
		}
		im.TableSetColumnIndex(3)
		im.TextUnformatted(fmt.ctprintf("%s", r.keys))
		im.TableSetColumnIndex(4)
		if r.down && !r.blocked do im.TextColored({0.4, 1, 0.4, 1}, "●")
		if r.blocked do im.PopStyleColor()
	}
}
