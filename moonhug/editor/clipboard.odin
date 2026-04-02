package editor

import engine "../engine"

Clipboard :: struct {
	hierarchy_data:   []byte,
	comp_type_key:    engine.TypeKey,
	comp_data:        [dynamic]byte,
}

@(private)
_clipboard: Clipboard = {
	comp_type_key = engine.INVALID_TYPE_KEY,
}
