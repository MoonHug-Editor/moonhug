package editor

// Escape in a text field keeps what was typed and drops the focus, in every
// window at once. imgui's InputText would put the pre-edit text back into
// its buffer on Escape, and it has no setting for anything else (imgui issue
// 6578: the author's answer is the key-owner API used below, still in
// imgui_internal). This runs right after im.NewFrame, before any widget
// draws, when an InputText is the active item and Escape was pressed:
//
// - The key is locked for the frame, so the field never sees it and neither
//   do the Escape handlers of other views (scene deselect, filter clears).
// - A field that commits on Enter (EnterReturnsTrue: object names, renames)
//   gets an Enter press queued instead, so it commits and deactivates next
//   frame like a real Enter.
// - Any other field is deactivated here. It reports a normal end of edit
//   (so the inspector's undo session closes) and its buffer keeps the typed
//   text, because InputText writes the caller's buffer on every edit.

import im "moonhug:external/odin-imgui"

// ImGuiInputFlags_LockThisFrame and ImGuiInputTextFlags_Multiline
// (imgui_internal.h): the binding's enums list only the public flags.
@(private = "file")
_INPUT_FLAGS_LOCK_THIS_FRAME := transmute(im.InputFlags)i32(1 << 20)
@(private = "file")
_INPUT_TEXT_FLAGS_MULTILINE := transmute(im.InputTextFlags)i32(1 << 26)

// True on a frame the hook took Escape from a text field: the key reads as
// unpressed for everyone else that frame, so a widget that also wants to act
// on that Escape (the Add Component popup closing) asks here.
@(private = "file") _escape_consumed: bool

text_input_escape_consumed :: proc() -> bool {
	return _escape_consumed
}

text_input_escape_frame :: proc() {
	_escape_consumed = false
	if !im.IsKeyPressed(.Escape, false) do return
	id := im.GetActiveID()
	if id == 0 do return
	state := im.GetInputTextState(id)
	if state == nil || state.ID_ != id do return
	_escape_consumed = true
	im.SetKeyOwner(.Escape, 0, _INPUT_FLAGS_LOCK_THIS_FRAME)
	if .EnterReturnsTrue in state.Flags && state.Flags & _INPUT_TEXT_FLAGS_MULTILINE == {} {
		io := im.GetIO()
		im.IO_AddKeyEvent(io, .Enter, true)
		im.IO_AddKeyEvent(io, .Enter, false)
	} else {
		im.ClearActiveID()
	}
}
