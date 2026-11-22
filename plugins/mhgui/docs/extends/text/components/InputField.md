---
title: "InputField"
description: "A control the user types text into, with a caret, a selection, the clipboard and a hint, and InputCaret, which draws the caret"
weight: 10
tags: ["mhgui", "text", "components", "input", "text field"]
---

A control the user types text into. GameObject, UI, Input Field creates one with every node it needs. The code is mhgui's `text` subpackage, which builds only with the text plugin installed.

## Example

```
Input Field       RectTransform, CanvasRenderer, UiShape, InputField
└── Text Area     RectTransform, CanvasRenderer, UiMask, InputCaret
    ├── Placeholder   RectTransform, CanvasRenderer, Text "Enter text..."
    └── Text          RectTransform, CanvasRenderer, Text
```

- The InputField holds the string and edits it. The Text shows it.
- The Text Area clips a line longer than the field, and its InputCaret draws the caret and the selection behind the glyphs.
- The Placeholder shows only while the field is empty.

## Properties

`interactable`, `transition`, `target_graphic`, `colors`, `sprites` and `navigation` are what every control has, as on a [Button](../../../components/Button.md).

| Field | Default | What it does |
|---|---|---|
| `text` | empty | The string the field holds. |
| `text_component` | none | The node with the Text that shows the string. The InputCaret on that node's parent draws the caret. |
| `placeholder` | none | A node that shows only while the field is empty: the hint. |
| `content` | Standard | Which characters the field takes, below. |
| `lines` | Single_Line | Single_Line: Enter submits. Multi_Line: Enter starts a new line, and the shortcut key with Enter submits. |
| `character_limit` | 0 | The most characters the field holds. 0 is no limit. |
| `read_only` | off | The text can be selected and copied, not changed. |
| `caret_color` | white | |
| `selection_color` | blue at half alpha | |
| `caret_width` | 2 | In canvas units. |
| `caret_blink_rate` | 1.2 | Blinks a second. 0 is a caret that does not blink. |

| Content | What the field takes |
|---|---|
| Standard | Any character. |
| Integer_Number | Digits, and a minus sign at the start. |
| Decimal_Number | Digits, a minus sign at the start and one point. |
| Alphanumeric | Letters and digits. |
| Password | Any character. The Text shows a dot for each, and copy and cut do nothing. |

## Behavior

- A press on the field starts the editing and puts the caret under the pointer. A drag selects, Shift with a press extends the selection, and a double click selects a word.
- The submit key on a field that keyboard or gamepad navigation selected starts the editing with everything selected.
- While it is edited the field has the keys: the arrow keys move the caret and do not move the selection to another control, and Space types a space.
- Enter ends the editing and sets `submitted`. Escape, a press outside the field, the selection moving to another control and the game losing the focus end it too. The text typed so far stays in every case.
- A single line longer than the Text Area scrolls so the caret stays in view. The field moves the Text node sideways while it is edited and puts it back after.
- A multi-line field wraps as its Text does (`wrap` on the Text) and does not scroll.
- The Text's own settings are the look: font, size, colour and alignment. Give it `wrap` off for a single line and `parse_escape_characters` off.

| Key | What it does |
|---|---|
| Left, Right | Move the caret. With Shift, select. |
| Option or Alt with Left, Right (Control on Windows and Linux) | Move by a word. |
| Home, End, and the shortcut key with Left, Right | Move to the start or the end of the line. |
| Up, Down | Multi_Line: move to the line above or below. Single_Line: to the start or the end. |
| Backspace, Delete | Delete the selection, or one character. With the word key, a word. |
| Shortcut key with A, C, X, V | Select all, copy, cut, paste. A line break pasted into a single line becomes a space. |
| Enter | Single_Line: submit. Multi_Line: a new line. |
| Escape | End the editing. |

The shortcut key is Command on macOS and Control on Windows and Linux.

## From code

```odin
import mhgui_text "moonhug:packages/mhgui/text"

@(update)
login_tick :: proc(dt: f32) {
	_, name := engine.transform_get_comp(name_node, mhgui_text.InputField)
	if mhgui_text.input_field_submitted(name) do log_in(name.text)
	if mhgui_text.input_field_changed(name) do validate(name.text)
}
```

| Proc | What it does |
|---|---|
| `input_field_changed` | True on the frame the text changed. |
| `input_field_submitted` | True on the frame Enter ended the editing. |
| `input_field_ended` | True on the frame the editing ended, by anything. |
| `input_field_set_text` | Replaces the string. Characters the content does not take are left out, and the limit cuts it. |
| `input_field_begin` | Starts the editing, as a press does. |
| `input_field_end` | Ends the editing. |

Poll from an `@(update)` proc at order 0 or later: the field updates at order -99.

## InputCaret

Draws the caret and the selection of the InputField that edits a Text under its node. It goes on the Text's parent, with a CanvasRenderer, and has no fields: the field gives it its colours. Without one the field works and shows no caret.

## Limits

- A multi-line field does not scroll.
- No input method window is placed at the caret: composed text arrives when it is committed.
- The caret draws behind the glyphs.
- On a gamepad there is no on-screen keyboard.
