package editor

// The command palette modes of the shell (docs/core/Keymaps.md): assets and views.
// The engine plugin adds scene objects.

import "core:slice"
import "core:strings"
import assets "moonhug:libs/assets"
import core "moonhug:libs/core"
import "moonhug:editor/command_palette"
import wnd "moonhug:editor/window"

// Every asset file by name with its Project view icon, its folder beside it,
// sorted by name. A term
// with a slash matches the path, so `#ui/` lists a folder's assets. Enter
// does what a double-click on the asset in the Project view does: it selects
// it and opens its document, a scene in the Scene view.
@(command_palette_mode={name="Assets", prefix="#", run=command_palette_assets_run, shortcut="Ctrl+Shift+A", help="Finds an asset by name or folder and opens it"})
command_palette_assets :: proc(query: string, rows: ^[dynamic]command_palette.Row) {
	ts := command_palette.terms(query)
	for path in assets.asset_db.path_to_guid {
		if assets.asset_db_is_dir(path) do continue
		cut := strings.last_index_any(path, "/\\")
		name, dir := path[cut + 1:], path[:max(cut, 0)]
		hit := true
		for term, i in ts {
			if command_palette.matches(name, ts[i:i + 1]) do continue
			if strings.contains_any(term, "/\\") && command_palette.contains_fold(path, term) do continue
			hit = false
			break
		}
		if hit do append(rows, command_palette.Row{label = name, detail = dir, icon = _project_file_icon(path), key = path})
	}
	slice.sort_by(rows[:], proc(a, b: command_palette.Row) -> bool {
		if a.label != b.label do return a.label < b.label
		return a.key < b.key
	})
}

command_palette_assets_run :: proc(row: command_palette.Row) {
	guid, ok := assets.asset_db_get_guid(row.key)
	if !ok do return
	core.inspector_request_select_asset(core.Asset_GUID(guid))
	_project_open_file(row.key)
}

// Every view by its label and icon, the open ones marked, sorted by label: an open
// view comes forward, in its Workspace frame when it is in one, and a closed
// one opens as the Window menu opens it.
@(command_palette_mode={name="Views", prefix=":", run=command_palette_views_run, help="Brings a view forward, or opens a closed one"})
command_palette_views :: proc(query: string, rows: ^[dynamic]command_palette.Row) {
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

command_palette_views_run :: proc(row: command_palette.Row) {
	w := wnd.find(row.key)
	switch {
	case w == nil:      wnd.open(row.key)
	case w.host != "": workspace_view_reveal(w.host, w.key)
	case:               wnd.focus(w)
	}
}
