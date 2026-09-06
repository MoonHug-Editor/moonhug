package editor

// Unity's Add Component popup over the Component menu tree: a search field
// on top, and under it either the tree one level at a time (categories open
// on click, the header's arrow goes back up) or, while the search has text,
// one flat list of every component whose name contains it, with its category
// beside it. Up and Down move the highlight, Enter adds the highlighted
// component, a click adds that one. Picking closes the popup, so does Escape,
// also while the search field has the focus.

import "core:strings"
import im "moonhug:external/odin-imgui"
import "menu"
import "moonhug:editor/widgets"

@(private = "file") _AC_WIDTH :: f32(260)
@(private = "file") _AC_LIST_HEIGHT :: f32(300)

@(private = "file") _ac_search: [64]u8
@(private = "file") _ac_path: [dynamic]^menu.MenuNode // the categories descended into, root first
@(private = "file") _ac_highlight: int

@(private = "file")
_Ac_Match :: struct {
	node:     ^menu.MenuNode,
	category: string, // "Sequencer/Tracks", "" at the root
}

// Call between BeginPopup and EndPopup.
add_component_popup_draw :: proc() {
	root := menu.node_at("Component")
	if root == nil do return
	if im.IsWindowAppearing() {
		_ac_search = {}
		clear(&_ac_path)
		_ac_highlight = 0
		im.SetKeyboardFocusHere()
	}

	if im.IsKeyPressed(.Escape, false) || text_input_escape_consumed() {
		im.CloseCurrentPopup()
		return
	}

	im.SetNextItemWidth(_AC_WIDTH)
	if im.InputTextWithHint("##ac_search", "Search", cstring(raw_data(_ac_search[:])), len(_ac_search)) {
		_ac_highlight = 0
	}
	query := strings.trim_space(string(cstring(raw_data(_ac_search[:]))))

	if query == "" {
		_ac_draw_tree(root)
	} else {
		_ac_draw_matches(root, query)
	}
}

// One level of the tree: the header names the category with an arrow back
// up, the list has its subcategories and components.
@(private = "file")
_ac_draw_tree :: proc(root: ^menu.MenuNode) {
	current := root
	if len(_ac_path) > 0 do current = _ac_path[len(_ac_path) - 1]
	if len(_ac_path) > 0 {
		if im.ArrowButton("##ac_back", .Left) do pop(&_ac_path)
		im.SameLine()
		im.TextUnformatted(current.name_cstr)
	} else {
		im.TextDisabled("Component")
	}
	im.Separator()
	if im.BeginChild("##ac_list", {_AC_WIDTH, _AC_LIST_HEIGHT}) {
		for child in current.children {
			switch child.kind {
			case .Submenu:
				if len(child.children) == 0 do continue
				if im.Selectable(child.name_cstr) do append(&_ac_path, child)
				im.SameLine(_AC_WIDTH - 24)
				im.TextDisabled(">")
			case .Action, .Toggle:
				im.BeginDisabled(!menu.node_enabled(child))
				if im.Selectable(child.name_cstr) do _ac_pick(child)
				im.EndDisabled()
			case .Separator:
				im.Separator()
			}
		}
	}
	im.EndChild()
}

// Every component matching the query, with its category. The query is words
// separated by spaces, every word has to appear in the name or the category
// ("track aud" finds Sequencer/Tracks/TrackAudio). The highlighted row
// follows the keyboard; Enter picks it.
@(private = "file")
_ac_draw_matches :: proc(root: ^menu.MenuNode, query: string) {
	matches := make([dynamic]_Ac_Match, context.temp_allocator)
	_ac_collect(root, "", widgets.search_terms(query), &matches)

	if im.IsKeyPressed(.DownArrow) do _ac_highlight += 1
	if im.IsKeyPressed(.UpArrow) do _ac_highlight -= 1
	_ac_highlight = clamp(_ac_highlight, 0, max(len(matches) - 1, 0))
	if len(matches) > 0 && (im.IsKeyPressed(.Enter) || im.IsKeyPressed(.KeypadEnter)) {
		_ac_pick(matches[_ac_highlight].node)
		return
	}

	im.TextDisabled("Search")
	im.Separator()
	if im.BeginChild("##ac_list", {_AC_WIDTH, _AC_LIST_HEIGHT}) {
		if len(matches) == 0 do im.TextDisabled("No components match")
		for m, i in matches {
			im.BeginDisabled(!menu.node_enabled(m.node))
			if im.Selectable(m.node.name_cstr, i == _ac_highlight) do _ac_pick(m.node)
			im.EndDisabled()
			if m.category != "" {
				im.SameLine()
				im.TextDisabled(strings.clone_to_cstring(m.category, context.temp_allocator))
			}
		}
	}
	im.EndChild()
}

@(private = "file")
_ac_collect :: proc(node: ^menu.MenuNode, category: string, words: []string, out: ^[dynamic]_Ac_Match) {
	for child in node.children {
		switch child.kind {
		case .Submenu:
			sub := child.name if category == "" else strings.concatenate({category, "/", child.name}, context.temp_allocator)
			_ac_collect(child, sub, words, out)
		case .Action, .Toggle:
			if widgets.search_match(strings.concatenate({category, "/", child.name}, context.temp_allocator), words) {
				append(out, _Ac_Match{node = child, category = category})
			}
		case .Separator:
		}
	}
}

@(private = "file")
_ac_pick :: proc(node: ^menu.MenuNode) {
	if !menu.node_enabled(node) do return
	if node.action != nil do node.action()
	im.CloseCurrentPopup()
}
