package inspector

// What a field's row is called. A struct's fields are named for code
// (`spot_angle`, `playerSpeed`) and shown as words ("Spot Angle", "Player
// Speed"). Only the shown text changes: the row's id, its path, its undo name
// and what the MCP tools address stay the field's own name.
//
// The field loop gives the row's label and its shown text to row_label_push.
// Whatever draws that label asks row_label_text for the text. A label the
// loop did not give (a custom row's "Mesh", a list element, a name from data
// such as a blackboard entry) is drawn as it is.

import "core:fmt"
import "core:strings"
import "core:unicode"

// Words written in capitals when they stand alone in a name.
@(private = "file")
_ACRONYMS := [?]string{"uv", "ui", "id", "ik", "fov", "hdr", "lod", "fps", "url", "guid", "rgb", "aa", "ssr", "ssao", "taa", "2d", "3d"}

// `spot_angle` and `spotAngle` as "Spot Angle". On temp memory.
field_display_name :: proc(name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	word := strings.builder_make(context.temp_allocator)
	flush :: proc(b, word: ^strings.Builder) {
		w := strings.to_string(word^)
		if len(w) == 0 do return
		if strings.builder_len(b^) > 0 do strings.write_byte(b, ' ')
		lower := strings.to_lower(w, context.temp_allocator)
		acronym := false
		for a in _ACRONYMS do if a == lower do acronym = true
		if acronym {
			strings.write_string(b, strings.to_upper(w, context.temp_allocator))
		} else {
			for r, i in w {
				strings.write_rune(b, unicode.to_upper(r) if i == 0 else r)
			}
		}
		strings.builder_reset(word)
	}
	prev: rune
	for r in name {
		switch {
		case r == '_':
			flush(&b, &word)
		case unicode.is_upper(r) && unicode.is_lower(prev):
			// camelCase: a capital after a small letter starts a word.
			flush(&b, &word)
			strings.write_rune(&word, r)
		case:
			strings.write_rune(&word, r)
		}
		prev = r
	}
	flush(&b, &word)
	if strings.builder_len(b) == 0 do return name
	return strings.to_string(b)
}

@(private = "file") _row_label: cstring
@(private = "file") _row_text: cstring

Row_Label :: struct {
	label, text: cstring,
}

// Names `text` as what the row with `label` shows, until row_label_pop.
row_label_push :: proc(label: cstring, text: cstring) -> Row_Label {
	prev := Row_Label{_row_label, _row_text}
	_row_label, _row_text = label, text
	return prev
}

row_label_pop :: proc(prev: Row_Label) {
	_row_label, _row_text = prev.label, prev.text
}

// The text to draw for `label`: the field's shown name when `label` is the
// field loop's own label, else `label`.
row_label_text :: proc(label: cstring) -> cstring {
	if label != nil && label == _row_label do return _row_text
	return label
}

// `label` for a tree node: the shown text, with the label as the node's id.
row_tree_label :: proc(label: cstring) -> cstring {
	if label != nil && label == _row_label do return fmt.ctprintf("%s###%s", _row_text, label)
	return label
}
