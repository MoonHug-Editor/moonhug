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

import "core:strings"
import "core:unicode"
import im "moonhug:external/odin-imgui"

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

// A foldout row: `label`'s text where every label of the panel starts, with
// a small fold arrow LEFT of it, in the room the gutter leaves. So a foldout
// lines up with the plain rows around it. A click on the arrow or the name
// folds or unfolds it, and it is closed at first unless `default_open`.
//
// The open state is kept in the window's storage under the label's id, as a
// tree node keeps its own. When it returns true the rows inside are indented
// and the caller ends them with im.TreePop().
row_foldout :: proc(label: cstring, default_open := false) -> bool {
	FOLD_ARROW_GAP :: f32(4)
	FOLD_ARROW_ALPHA :: f32(0.6)
	id := im.GetID(label)
	storage := im.GetStateStorage()
	open := im.Storage_GetBool(storage, id, default_open)

	text := row_label_text(label)
	text_end := im.FindRenderedTextEnd(text)
	pos := im.GetCursorScreenPos()
	height := im.GetFrameHeight()
	half := im.GetFontSize() * 0.28
	arrow_w := half * 2 + FOLD_ARROW_GAP
	width := arrow_w + max(im.CalcTextSize(text, text_end).x, 1)

	// One item over the arrow and the name: the row's context menu and the
	// length a list draws after it attach to it.
	im.SetCursorScreenPos({pos.x - arrow_w, pos.y})
	if im.InvisibleButton(label, {width, height}) {
		open = !open
		im.Storage_SetBool(storage, id, open)
	}

	// The arrow may reach into the window's padding, which the window clips.
	dl := im.GetWindowDrawList()
	lo, hi := im.DrawList_GetClipRectMin(dl), im.DrawList_GetClipRectMax(dl)
	im.DrawList_PushClipRect(dl, {min(lo.x, pos.x - arrow_w), lo.y}, hi, false)
	c := im.Vec2{pos.x - FOLD_ARROW_GAP - half, pos.y + height * 0.5}
	ink := im.GetColorU32(.Text, FOLD_ARROW_ALPHA)
	if open {
		im.DrawList_AddTriangleFilled(dl, {c.x - half, c.y - half * 0.6}, {c.x + half, c.y - half * 0.6}, {c.x, c.y + half * 0.8}, ink)
	} else {
		im.DrawList_AddTriangleFilled(dl, {c.x - half * 0.6, c.y - half}, {c.x + half * 0.8, c.y}, {c.x - half * 0.6, c.y + half}, ink)
	}
	im.DrawList_AddText(dl, {pos.x, pos.y + im.GetStyle().FramePadding.y}, im.GetColorU32(.Text), text, text_end)
	im.DrawList_PopClipRect(dl)

	if open do im.TreePush(label)
	return open
}
