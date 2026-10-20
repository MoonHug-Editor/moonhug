package input_actions_editor

// The Key_Name field in the inspector (docs/InputActions.md): a button
// with the name that opens a picker, a search field over every control by
// device, and Listen, which takes the next key, mouse button or gamepad
// button pressed. The field loop wraps the drawer in field_edit_row, so a
// pick is one undo step.

import "core:strings"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/inspector"
import "moonhug:editor/widgets"
import engine "moonhug:packages/engine"
import actions "moonhug:packages/input_actions"

@(provider_install)
_register_key_drawer :: proc() {
	inspector.add_property_drawer(typeid_of(actions.Key_Name), draw_key_name)
	// The open document reaches the running game every frame, saved or not,
	// as the Render Layers and Material documents do.
	inspector.add_asset_doc_hook(typeid_of(actions.Input_Actions), {
		after = proc(doc: ^inspector.Asset_Doc) {
			actions.actions_preview(doc.guid, (cast(^actions.Input_Actions)doc.data.data)^)
		},
	})
	inspector.doc_preview_register(typeid_of(actions.Input_Actions), proc(guid: engine.Asset_GUID, doc: any) {
		actions.actions_preview(guid, (cast(^actions.Input_Actions)doc.data)^)
	})
}

@(private = "file") _search: [64]u8
@(private = "file") _listening: bool

draw_key_name :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	name := cast(^actions.Key_Name)ptr
	shown := len(name^) > 0 ? string(name^) : "None"
	if im.Button(strings.clone_to_cstring(shown, context.temp_allocator), {im.GetContentRegionAvail().x, 0}) {
		_search = {}
		_listening = false
		im.OpenPopup("##control_picker")
	}
	widgets.tooltip("The control driving this binding: pick one, or Listen and press it")
	if !im.BeginPopup("##control_picker") do return
	defer im.EndPopup()

	if im.IsWindowAppearing() do im.SetKeyboardFocusHere()
	im.SetNextItemWidth(220)
	im.InputTextWithHint("##control_search", "Search", cstring(raw_data(_search[:])), len(_search))
	im.SameLine()
	// Captured before the click flips it, so the pop matches the push.
	listening := _listening
	if listening do im.PushStyleColorImVec4(.Button, im.GetStyleColorVec4(.ButtonActive)^)
	if im.Button("Listen") do _listening = !_listening
	if listening do im.PopStyleColor()
	widgets.tooltip("Press the key, mouse button or gamepad button to bind")

	if _listening {
		im.TextDisabled("Press a control...")
		if got := actions.key_pressed_now(); got != "" {
			_set(name, got)
			_listening = false
			im.CloseCurrentPopup()
			return
		}
	}

	query := strings.trim_space(string(cstring(raw_data(_search[:]))))
	if im.BeginChild("##control_list", {260, 300}, {.FrameStyle}, {}) {
		for n in actions.key_names() {
			if query != "" && !strings.contains(strings.to_lower(n, context.temp_allocator), strings.to_lower(query, context.temp_allocator)) do continue
			if im.Selectable(strings.clone_to_cstring(n, context.temp_allocator), n == string(name^)) {
				_set(name, n)
				im.CloseCurrentPopup()
			}
		}
	}
	im.EndChild()
}

// Asset strings live on context.allocator, as the string drawer's do.
@(private = "file")
_set :: proc(name: ^actions.Key_Name, value: string) {
	delete(string(name^))
	name^ = actions.Key_Name(strings.clone(value))
	inspector.mark_inspector_changed()
}
