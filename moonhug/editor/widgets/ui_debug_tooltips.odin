package widgets

// Debug tooltips: a toggle that makes every UI element say what created it.
// Hovering shows the element's normal tooltip, a rule, and then — dimmed, so
// provenance never competes with the tooltip's own message — where it came
// from.
//
// Two kinds of element, two kinds of answer:
//
//   - REGISTERED through a prebuild attribute: the attribute as written, the
//     file and line it sits on, and the declaration's name. A generator renders
//     that string at build time (gen_core.AttrOrigin) and emits it into the
//     registration call, the owning registry stores it and pushes it as an
//     ambient value around the element's draw, and tooltip() reads it.
//   - HAND-DRAWN, nothing registered it: "built-in" and the file:line of the
//     tooltip call itself, from #caller_location. Free, compile-time, and it
//     means a toolbar button drawn straight in view_toolbar.odin is one hover
//     from its source the same as a registered one.
//
// This file lives in widgets because widgets imports nothing from the editor,
// so every registry — menu included — can reach it without an import cycle.

import "base:runtime"
import "core:fmt"
import "core:strings"
import im "moonhug:external/odin-imgui"

// @(menu_item) on a bool variable is a toggle, and this package is inside a
// scan root, so the menu entry costs nothing beyond the attribute.
@(menu_item={path="Help/Debug Tooltips", order=998})
ui_debug_tooltips := false

@(private = "file") _ui_origin: string

// ui_origin_push / ui_origin_pop bracket the draw of one registered element.
// Immediate mode makes an ambient value enough: the element's draw runs to
// completion before the next one starts, so anything calling tooltip() inside
// it belongs to that element. Save and restore rather than set and clear, so a
// registered element that draws nested registered elements does not leave the
// inner origin behind.
ui_origin_push :: proc(origin: string) -> (prev: string) {
	prev = _ui_origin
	_ui_origin = origin
	return
}

ui_origin_pop :: proc(prev: string) {
	_ui_origin = prev
}

// The element's regular tooltip, plus its origin while debug tooltips are on.
// `text` may be "" for an element with no tooltip of its own (a menu item):
// debug tooltips then shows the origin alone, and normal mode shows nothing.
//
// The hover test is done here, so a call site is one line and cannot forget
// the flags it needs — pass `flags` for a control that must talk while
// disabled (im.HoveredFlags_AllowWhenDisabled).
//
// `loc` defaults to the call site and is only read for a hand-drawn element.
// A widget helper that draws on behalf of its caller (icon_button) forwards
// its own `loc` parameter, or every button through it would name the helper.
tooltip :: proc(text: cstring, flags: im.HoveredFlags = {}, loc := #caller_location) {
	if !im.IsItemHovered(flags) do return
	_tooltip_show(text, loc)
}

// Same, for a caller that hit-tests itself: a widget painted into the draw
// list has no imgui item to ask about, so it decides when the pointer is on it.
tooltip_unchecked :: proc(text: cstring, loc := #caller_location) {
	_tooltip_show(text, loc)
}

@(private = "file")
_tooltip_show :: proc(text: cstring, loc: runtime.Source_Code_Location) {
	has_text := text != nil && text != ""
	if !ui_debug_tooltips {
		if has_text do im.SetTooltipUnformatted(text)
		return
	}
	if !im.BeginTooltip() do return
	defer im.EndTooltip()
	if has_text {
		im.TextUnformatted(text)
		im.Separator()
	}
	if _ui_origin != "" {
		_draw_origin(_ui_origin)
	} else {
		_dim("built-in")
		_dim(fmt.tprintf("%s:%d", _repo_relative(loc.file_path), loc.line))
	}
}

// An origin reads "@(attr k=v ...)  file:line  name" — three parts, two spaces
// between. The attribute is the answer, so it keeps full strength. The
// location and name are where to go next, so they sit dimmed under it.
@(private = "file")
_draw_origin :: proc(origin: string) {
	parts := strings.split(origin, "  ", context.temp_allocator)
	im.TextUnformatted(strings.clone_to_cstring(parts[0], context.temp_allocator))
	for p in parts[1:] do _dim(p)
}

// Dimmed text through TextUnformatted rather than TextDisabled, which takes a
// format string and would misread a '%' in a path or a label.
@(private = "file")
_dim :: proc(s: string) {
	im.PushStyleColorImVec4(.Text, im.GetStyleColorVec4(.TextDisabled)^)
	im.TextUnformatted(strings.clone_to_cstring(s, context.temp_allocator))
	im.PopStyleColor()
}

// #caller_location paths are absolute. The part from the repo's source roots
// on is what a reader wants, and it keeps a build machine's home directory out
// of a user-visible tooltip.
@(private = "file")
_repo_relative :: proc(path: string) -> string {
	for root in ([2]string{"/moonhug/", "/plugins/"}) {
		if i := strings.index(path, root); i >= 0 do return path[i + 1:]
	}
	return path
}
