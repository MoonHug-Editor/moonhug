package widgets

// Modal dialog built from a config: title, description, optional icon, and
// any number of buttons.
//
// - Any code opens it (a menu action, a key handler, a tool). The editor draws
//   it once per frame from the main loop, so OpenPopup and BeginPopupModal
//   always run in the same ID scope, whoever opened it.
// - One dialog at a time. Opening another replaces the open one.
// - Enter presses the default button, Escape and the title bar close button
//   press the cancel button.
// - Actions take no arguments. Odin procs carry no closure, so a dialog's
//   state lives in the caller's file-level variables. One dialog is open at a
//   time, so one set of variables per dialog kind is enough.
// - The dialog closes BEFORE the action runs, so an action may open the next
//   dialog.

import "base:runtime"
import "core:strings"
import im "moonhug:external/odin-imgui"

Dialog_Button :: struct {
	label:      string,
	action:     proc(), // nil: the button only closes the dialog
	is_default: bool,               // Enter presses it, drawn highlighted
	is_cancel:  bool,               // Escape and the close button press it
}

Dialog :: struct {
	title:       string,
	description: string,
	icon:        cstring, // optional glyph from editor/icons
	buttons:     []Dialog_Button,
}

// Font for the icon, drawn at DIALOG_ICON_SIZE. The editor sets it at font
// init (widgets can't import the editor). Nil falls back to the current font.
dialog_icon_font: ^im.Font

DIALOG_ICON_SIZE :: f32(40)
DIALOG_TEXT_WIDTH :: f32(380)
DIALOG_BUTTON_MIN_WIDTH :: f32(90)

@(private = "file")
_DIALOG_ID :: "###moonhug_dialog"

@(private = "file")
_dialog: Dialog // owned clones of the open dialog's strings and buttons
@(private = "file")
_dialog_is_open: bool
@(private = "file")
_dialog_wants_popup: bool // opened since the last draw

// Clones the config, so the caller may pass temp strings.
dialog_open :: proc(d: Dialog) {
	context.allocator = runtime.default_allocator()
	_dialog_free()
	buttons := make([]Dialog_Button, len(d.buttons))
	for b, i in d.buttons {
		buttons[i] = b
		buttons[i].label = strings.clone(b.label)
	}
	_dialog = Dialog{
		title       = strings.clone(d.title),
		description = strings.clone(d.description),
		icon        = d.icon,
		buttons     = buttons,
	}
	_dialog_is_open = true
	_dialog_wants_popup = true
}

dialog_is_open :: proc() -> bool {
	return _dialog_is_open
}

// The open dialog, for tests and tools. Valid until it closes.
dialog_current :: proc() -> (d: Dialog, ok: bool) {
	return _dialog, _dialog_is_open
}

// Presses button `index` of the open dialog: closes it, then runs the action.
// The draw loop calls it for clicks and keys. Tests and tools call it directly.
dialog_choose :: proc(index: int) {
	assert(_dialog_is_open, "dialog_choose: no dialog is open")
	assert(index >= 0 && index < len(_dialog.buttons), "dialog_choose: button index out of range")
	action := _dialog.buttons[index].action
	dialog_close()
	if action != nil do action()
}

// Closes without pressing a button (no action runs).
dialog_close :: proc() {
	_dialog_free()
	_dialog_is_open = false
	_dialog_wants_popup = false
}

// Called once per frame from the main loop, outside every window.
dialog_draw :: proc() {
	if !_dialog_is_open && !im.IsPopupOpen(_DIALOG_ID) do return
	if _dialog_wants_popup {
		_dialog_wants_popup = false
		im.OpenPopup(_DIALOG_ID)
	}

	cancel := -1
	for b, i in _dialog.buttons do if b.is_cancel { cancel = i; break }

	vp := im.GetMainViewport()
	im.SetNextWindowPos(vp.Pos + vp.Size * 0.5, .Appearing, im.Vec2{0.5, 0.5})
	title := strings.clone_to_cstring(strings.concatenate({_dialog.title, _DIALOG_ID}, context.temp_allocator), context.temp_allocator)
	keep_open := true
	// The close button shows only when a button means "cancel".
	p_open: ^bool = &keep_open if cancel >= 0 else nil
	if !im.BeginPopupModal(title, p_open, {.AlwaysAutoResize, .NoSavedSettings}) {
		// Closed by imgui (the close button): same as pressing cancel.
		if _dialog_is_open && !keep_open && cancel >= 0 do dialog_choose(cancel)
		return
	}
	defer im.EndPopup()

	// dialog_choose ran outside the draw (a test, a tool): the popup follows.
	if !_dialog_is_open {
		im.CloseCurrentPopup()
		return
	}

	_dialog_draw_body()
	chosen := _dialog_draw_buttons()

	if chosen < 0 && im.IsWindowFocused() {
		if im.IsKeyPressed(.Enter) || im.IsKeyPressed(.KeypadEnter) {
			for b, i in _dialog.buttons do if b.is_default { chosen = i; break }
		} else if im.IsKeyPressed(.Escape) {
			chosen = cancel
		}
	}
	if chosen >= 0 {
		im.CloseCurrentPopup()
		dialog_choose(chosen)
	}
}

@(private = "file")
_dialog_draw_body :: proc() {
	if _dialog.icon != nil {
		im.PushFontFloat(dialog_icon_font, DIALOG_ICON_SIZE)
		im.TextUnformatted(_dialog.icon)
		im.PopFont()
		im.SameLine(0, im.GetStyle().ItemSpacing.x * 2)
	}
	im.BeginGroup()
	im.PushTextWrapPos(im.GetCursorPosX() + DIALOG_TEXT_WIDTH)
	desc := strings.clone_to_cstring(_dialog.description, context.temp_allocator)
	im.TextUnformatted(desc)
	im.PopTextWrapPos()
	im.EndGroup()
	im.Spacing()
	im.Spacing()
}

// Buttons in config order, centered, all one width.
// Returns the pressed index or -1.
@(private = "file")
_dialog_draw_buttons :: proc() -> int {
	style := im.GetStyle()
	w := DIALOG_BUTTON_MIN_WIDTH
	for b in _dialog.buttons {
		label := strings.clone_to_cstring(b.label, context.temp_allocator)
		w = max(w, im.CalcTextSize(label).x + style.FramePadding.x * 4)
	}
	n := f32(len(_dialog.buttons))
	row := w * n + style.ItemSpacing.x * max(n - 1, 0)
	im.SetCursorPosX(im.GetCursorPosX() + max(im.GetContentRegionAvail().x - row, 0) * 0.5)

	chosen := -1
	for b, i in _dialog.buttons {
		if i > 0 do im.SameLine()
		label := strings.clone_to_cstring(b.label, context.temp_allocator)
		if b.is_default {
			im.PushStyleColorImVec4(.Button, im.GetStyleColorVec4(.ButtonHovered)^)
			im.PushStyleColorImVec4(.ButtonHovered, im.GetStyleColorVec4(.ButtonActive)^)
		}
		if im.Button(label, im.Vec2{w, 0}) do chosen = i
		if b.is_default {
			im.PopStyleColor(2)
			im.SetItemDefaultFocus()
		}
	}
	return chosen
}

@(private = "file")
_dialog_free :: proc() {
	context.allocator = runtime.default_allocator()
	delete(_dialog.title)
	delete(_dialog.description)
	for b in _dialog.buttons do delete(b.label)
	delete(_dialog.buttons)
	_dialog = {}
}
