package editor

// The command palette modes of the shell (docs/core/Keymaps.md): assets and windows.
// The engine plugin adds scene objects.

import "core:fmt"
import "core:slice"
import "core:strings"
import assets "moonhug:libs/assets"
import core "moonhug:libs/core"
import "moonhug:editor/command_palette"
import wnd "moonhug:editor/window"

// Every asset file by name with its Project window icon, its folder beside it,
// sorted by name: what the Project window's search finds for the same words
// (asset_search.odin), "t:" and "c:" included, without the folders. A term
// with a slash matches the path, so `#ui/` lists a folder's assets. A scene
// file's sub-asset is a row with its file beside it. Enter does what a
// double-click on the asset in the Project window does: it selects it and
// opens its document, a scene in the Scene window.
@(command_palette_mode={name="Assets", prefix="#", run=command_palette_assets_run, shortcut="Ctrl+Shift+A", help="Finds an asset by name, folder, type (t:) or root component (c:) and opens it"})
command_palette_assets :: proc(query: string, rows: ^[dynamic]command_palette.Row) {
	hits := make([dynamic]Asset_Hit, context.temp_allocator)
	asset_search(query, command_palette.matches, &hits)
	for &h in hits {
		if h.is_dir do continue
		cut := strings.last_index_any(h.path, "/\\")
		name, dir := h.path[cut + 1:], h.path[:max(cut, 0)]
		if h.sub != 0 {
			append(rows, command_palette.Row{label = h.sub_name, detail = h.path, icon = _project_file_icon(h.path), key = fmt.tprintf("%s:%d", h.path, i64(h.sub)), data = &h})
		} else {
			append(rows, command_palette.Row{label = name, detail = dir, icon = _project_file_icon(h.path), key = h.path, data = &h})
		}
	}
	slice.sort_by(rows[:], proc(a, b: command_palette.Row) -> bool {
		if a.label != b.label do return a.label < b.label
		return a.key < b.key
	})
}

command_palette_assets_run :: proc(row: command_palette.Row) {
	h := (^Asset_Hit)(row.data)
	guid, ok := assets.asset_db_get_guid(h.path)
	if !ok do return
	if h.sub != 0 {
		// As a double click on a reference to it: selected in the Project window.
		core.inspector_request_open_asset(core.Asset_GUID(guid), h.sub)
		return
	}
	core.inspector_request_select_asset(core.Asset_GUID(guid))
	_project_open_file(h.path)
}

// Every window by its label and icon, the open ones marked, sorted by label: an open
// window comes forward, in its Workspace frame when it is in one, and a closed
// one opens as the Window menu opens it.
@(command_palette_mode={name="Windows", prefix=":", run=command_palette_windows_run, help="Brings a window forward, or opens a closed one"})
command_palette_windows :: proc(query: string, rows: ^[dynamic]command_palette.Row) {
	ts := command_palette.terms(query)
	for r in wnd.registered() {
		open := wnd.instances(r.id)
		if len(open) == 0 {
			if command_palette.matches(r.title, ts) do append(rows, command_palette.Row{label = r.title, icon = r.icon, key = r.id})
			continue
		}
		for w in open {
			label := wnd.label(w)
			if command_palette.matches(label, ts) do append(rows, command_palette.Row{label = label, detail = "Open", icon = r.icon, key = w.key})
		}
	}
	slice.sort_by(rows[:], proc(a, b: command_palette.Row) -> bool {
		if a.label != b.label do return a.label < b.label
		return a.key < b.key
	})
}

command_palette_windows_run :: proc(row: command_palette.Row) {
	w := wnd.find(row.key)
	switch {
	case w == nil:      wnd.open(row.key)
	case w.host != "": workspace_window_reveal(w.host, w.key)
	case:               wnd.focus(w)
	}
}
