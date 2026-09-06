package core

// Process-wide application state that every layer may ask about, Unity's
// Application.* flags that are not tied to a world. isEditor and isPlaying
// live on engine.UserContext; this one sits here because the input layer
// gates on it and input cannot import engine.

// Unity's Application.isFocused. Standalone it is the window's focus; in the
// editor it is the Game view's focus during a run. The host (platform or
// editor) writes it through engine/input, which also freezes the mouse and
// filters the fixed-tick edges on the change. Reads start true so a game
// that runs before the first focus event is not blind.
@(private = "file")
_application_focused := true

application_is_focused :: proc() -> bool {
	return _application_focused
}

// For the host layer only (engine/input); game code reads.
application_set_focused :: proc(on: bool) {
	_application_focused = on
}
