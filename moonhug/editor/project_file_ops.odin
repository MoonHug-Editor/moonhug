package editor

// Project-window file operations. The Assets/... menu (appearing in BOTH the
// top Assets menu and the Project window's right-click menu) carries Unity's
// top section: Create | Reveal in Finder, Open, Delete, Rename, Copy Path |
// Open Scene Additive. Cut/Copy/Paste/Duplicate are shortcut-only, like
// Finder: cmd+C/X/V/D and cmd+Backspace in _project_handle_list_keys.
//
// Guid rules (the part that keeps references alive):
// - Cut/Paste MOVES the .meta with the asset — same asset, new path, guid
//   preserved, references survive (mirrors rename).
// - Copy/Paste and Duplicate never copy .meta — the copy is a NEW asset and
//   mints a fresh guid on refresh.
// - Delete asks for confirmation, then trashes the .meta with the asset
//   (recoverable together).
//
// Deletes go to the OS Trash (project_os_darwin.odin), never permanent.
// File operations are NOT undoable (see docs/core/Undo.md non-goals).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import strings "core:strings"
import "core:encoding/uuid"
import im "moonhug:external/odin-imgui"
import asset_pipeline "moonhug:editor/assets"
import clip "moonhug:editor/clipboard"
import "moonhug:editor/icons"
import "moonhug:editor/widgets"
import assets "moonhug:libs/assets"
import "moonhug:libs/serialization"
import core "moonhug:libs/core"
import "moonhug:editor/keymap"
import "moonhug:editor/inspector"
import "moonhug:editor/subassets"
import "moonhug:editor/undo"

// --- File clipboard -----------------------------------------------------------
// Cut and Copy put the selected files on the editor's clipboard (clipboard
// package), which a later copy of anything else replaces.

project_file_ops_shutdown :: proc() {
	_project_delete_pending_clear()
}

// Cut files draw dimmed in the list (Finder/Explorer convention).
project_file_is_cut :: proc(path: string) -> bool {
	if !clip.files_cut() do return false
	for p in clip.files() {
		if p == path do return true
	}
	return false
}

@(private = "file")
_file_clip_set :: proc(cut: bool) {
	paths := make([dynamic]string, context.temp_allocator)
	for p in sel_proj_items() {
		// Roots (Assets, Packages, package roots) are structural, not files.
		if project_path_is_protected(p) do continue
		append(&paths, p)
	}
	clip.copy_files(paths[:], cut)
}

// --- Op helpers ---------------------------------------------------------------

// dir/name, or dir/"name N" when taken (extension preserved for files).
// `sep` goes between the name and the number: a space for folders and copies,
// none for a new asset's file name.
@(private = "file")
_project_unique_dest :: proc(dir, name: string, sep := " ") -> string {
	dst, _ := filepath.join({dir, name}, context.temp_allocator)
	if !os.exists(dst) do return dst
	stem := filepath.stem(name)
	ext := filepath.ext(name) // "" for folders, ".mat" style for files
	for i in 1 ..< 1000 {
		cand, _ := filepath.join({dir, fmt.tprintf("%s%s%d%s", stem, sep, i, ext)}, context.temp_allocator)
		if !os.exists(cand) do return cand
	}
	return dst
}

// Recursive copy that SKIPS every .meta — copies are new assets and must
// mint fresh guids on refresh.
@(private = "file")
_project_copy_recursive :: proc(src, dst: string) -> bool {
	if os.is_dir(src) {
		if os.make_directory(dst) != nil do return false
		handle, err := os.open(src)
		if err != nil do return false
		defer os.close(handle)
		entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
		if rerr != nil do return false
		defer os.file_info_slice_delete(entries, context.temp_allocator)
		ok := true
		for entry in entries {
			if strings.has_suffix(entry.name, ".meta") do continue
			sub_src, _ := filepath.join({src, entry.name}, context.temp_allocator)
			sub_dst, _ := filepath.join({dst, entry.name}, context.temp_allocator)
			if !_project_copy_recursive(sub_src, sub_dst) do ok = false
		}
		return ok
	}
	data, rerr := os.read_entire_file(src, context.temp_allocator)
	if rerr != nil do return false
	return os.write_entire_file(dst, data) == nil
}

// Move with the .meta (guid preserved — mirrors _project_apply_rename).
@(private = "file")
_project_move :: proc(src, dst: string) -> bool {
	if err := os.rename(src, dst); err != nil {
		fmt.printf("[Editor] Move %s -> %s failed: %v\n", src, dst, err)
		return false
	}
	old_meta := strings.concatenate({src, ".meta"}, context.temp_allocator)
	if os.exists(old_meta) {
		new_meta := strings.concatenate({dst, ".meta"}, context.temp_allocator)
		os.rename(old_meta, new_meta)
	}
	return true
}

@(private = "file")
_project_select_paths :: proc(paths: []string) {
	if len(paths) == 0 do return
	_project_set_selected(paths[0])
	for p in paths[1:] {
		sel_proj_add(p)
	}
	_project_set_active(paths[len(paths) - 1])
	_pv.scroll_to_list_sel = true
}

// --- Operations (menu items + shortcuts call these) ----------------------------

project_ops_new_folder :: proc() {
	dir := _pv.current_path
	if dir == "" do return
	if dir == _PROJECT_PACKAGES_PATH {
		fmt.println("[Editor] New Folder: packages are managed on disk (moonhug/packages), not here")
		return
	}
	dst := _project_unique_dest(dir, "New Folder")
	if os.make_directory(dst) != nil {
		fmt.printf("[Editor] New Folder: failed to create %s\n", dst)
		return
	}
	asset_pipeline.asset_db_refresh()
	project_dir_cache_invalidate()
	_project_set_selected(dst)
	_project_begin_rename(dst, false)
}

// Assets ▸ Create ▸ <type>: a new asset of that type with its reset defaults,
// in the open folder under a free file name (`file_name`, numbered when
// taken), then known to the asset database, selected and ready to rename, as
// New Folder does. The generated create menu items call it.
project_ops_create_asset :: proc(file_name: string, type_key: core.TypeKey) {
	// With a sub-asset selected, the new asset is a sub-asset of the same
	// file, where that file takes one and the type can live inside another
	// file. Otherwise it is a file.
	if path, sub, is_sub := _project_selected_sub(); is_sub {
		if _project_create_sub_asset(path, sub, file_name, type_key) do return
	}
	dir := _pv.current_path
	if dir == "" do return
	if dir == _PROJECT_PACKAGES_PATH {
		fmt.println("[Editor] Create: the Packages node lists packages, not files — create inside a package's content instead")
		return
	}
	dst := _project_unique_dest(dir, file_name, sep = "")
	instance := core.create_instance_by_type_key(type_key)
	defer {
		core.type_cleanup(type_key, instance.data)
		free(instance.data)
	}
	if !serialization.write_asset_to_path(dst, core.get_guid_by_type_key(type_key), instance) {
		fmt.printf("[Editor] Create: failed to write %s\n", dst)
		return
	}
	asset_pipeline.asset_db_refresh()
	project_dir_cache_invalidate()
	_project_set_selected(dst)
	_project_begin_rename(dst, false)
}

// Adds a new asset of the type to the file that holds the selected sub-asset
// `sub`, as one undo step, selects it and opens its name for typing. The
// kind and the name come from the file name Assets > Create gives the type
// ("New Material.mat"). False when the file takes no new sub-asset now, or
// the type cannot live inside another file: the caller makes a file.
@(private = "file")
_project_create_sub_asset :: proc(path: string, sub: core.Local_ID, file_name: string, type_key: core.TypeKey) -> bool {
	ref, provider, ok := _project_sub_ref(path, sub)
	if !ok || provider.create == nil do return false
	kind := strings.trim_prefix(strings.to_lower(filepath.ext(file_name), context.temp_allocator), ".")
	if !subassets.can_live_inside(kind) do return false
	name := subassets.unique_name(ref.guid, filepath.stem(file_name))
	instance := core.create_instance_by_type_key(type_key)
	defer {
		core.type_cleanup(type_key, instance.data)
		free(instance.data)
	}
	owner_path := strings.clone(path, context.temp_allocator) // the selection owns `path`
	created, made := provider.create(ref.guid, kind, name, instance)
	if !made do return false
	sel_proj_only(owner_path, created.local_id)
	_project_set_active(owner_path)
	_project_unfold_sub_assets(owner_path)
	_project_inspectors_refresh()
	_project_begin_rename_sub(owner_path, created.local_id)
	return true
}

project_ops_show_in_finder :: proc() {
	target := projectWindowData.selectedFile
	if target == "" do target = _pv.current_path
	if target == "" do return
	file_reveal_in_os(target)
}

project_ops_cut :: proc() {
	if sel_proj_count() == 0 {
		fmt.println("[Editor] Cut: select files first")
		return
	}
	_file_clip_set(cut = true)
}

project_ops_copy :: proc() {
	if sel_proj_count() == 0 {
		fmt.println("[Editor] Copy: select files first")
		return
	}
	_file_clip_set(cut = false)
}

// Whether a paste would do anything: a Cut or Copy left files to paste.
project_ops_can_paste :: proc() -> bool {
	return len(clip.files()) > 0 || keymap.disabled("No files were copied")
}

project_ops_paste :: proc() {
	if len(clip.files()) == 0 {
		fmt.println("[Editor] Paste: clipboard is empty (Cut or Copy files first)")
		return
	}
	dst_dir := _pv.current_path
	if dst_dir == "" do return
	if dst_dir == _PROJECT_PACKAGES_PATH {
		fmt.println("[Editor] Paste: the Packages node lists packages, not files — paste inside a package's content instead")
		return
	}

	pasted := make([dynamic]string, context.temp_allocator)
	cut := clip.files_cut()
	for src in clip.files() {
		if !os.exists(src) do continue
		if cut {
			// Moving a folder into itself/its subtree would orphan it.
			prefix := strings.concatenate({src, "/"}, context.temp_allocator)
			if dst_dir == src || strings.has_prefix(dst_dir, prefix) {
				fmt.printf("[Editor] Paste: can't move %s into itself\n", src)
				continue
			}
			if filepath.dir(src) == dst_dir do continue // no-op move
			dst := _project_unique_dest(dst_dir, filepath.base(src))
			if _project_move(src, dst) do append(&pasted, dst)
		} else {
			dst := _project_unique_dest(dst_dir, filepath.base(src))
			if _project_copy_recursive(src, dst) do append(&pasted, dst)
		}
	}
	// A cut clipboard is one-shot (Finder/Explorer semantics).
	if cut do clip.clear_files()
	asset_pipeline.asset_db_refresh()
	project_dir_cache_invalidate()
	_project_select_paths(pasted[:])
}

project_ops_duplicate :: proc() {
	srcs := slice.clone(sel_proj_items(), context.temp_allocator)
	if len(srcs) == 0 {
		// Sub-assets only: each gets a copy inside its file, an undo step
		// like any edit of that file. A file of its own is Duplicate as Asset.
		if !project_ops_duplicate_as_sub_asset() do fmt.println("[Editor] Duplicate: select files first")
		return
	}
	dups := make([dynamic]string, context.temp_allocator)
	for src in srcs {
		if !os.exists(src) do continue
		dst := _project_unique_dest(filepath.dir(src), filepath.base(src))
		if _project_copy_recursive(src, dst) do append(&dups, dst)
	}
	asset_pipeline.asset_db_refresh()
	project_dir_cache_invalidate()
	_project_select_paths(dups[:])
}

// The selected sub-assets, their paths on the temp allocator: the selection
// changes while a copy of each is made.
@(private = "file")
_project_selected_sub_assets :: proc() -> []Proj_Sel {
	subs := make([dynamic]Proj_Sel, context.temp_allocator)
	for e in sel_proj_entries() {
		if e.sub_id != 0 do append(&subs, Proj_Sel{path = strings.clone(e.path, context.temp_allocator), sub_id = e.sub_id})
	}
	return subs[:]
}

// Duplicate, for sub-assets: a copy of each selected sub-asset in the file that
// holds it, where the file takes one (subassets.Provider.create) and the
// sub-asset is a document, as one undo step. The copies are selected.
// Returns whether the selection held a sub-asset.
project_ops_duplicate_as_sub_asset :: proc() -> bool {
	subs := _project_selected_sub_assets()
	if len(subs) == 0 do return false
	g := undo.group_begin("Duplicate Sub-Assets")
	defer undo.group_end(&g)
	first := true
	for e in subs {
		ref, provider, ok := _project_sub_ref(e.path, e.sub_id)
		source, found := subassets.get(ref)
		doc := inspector.asset_doc_get_ref(ref) if ok && found else nil
		if doc == nil || provider.create == nil {
			fmt.printf("[Editor] Duplicate: the importer of %s makes its sub-assets, they are not copied\n", e.path)
			continue
		}
		kind := strings.clone(source.kind, context.temp_allocator)
		name := subassets.unique_name(ref.guid, source.name)
		copied, made := provider.create(ref.guid, kind, name, doc.data)
		if !made {
			fmt.printf("[Editor] Duplicate: a sub-asset of %s is not copied\n", e.path)
			continue
		}
		if first do sel_proj_only(e.path, copied.local_id)
		else do sel_proj_add(e.path, copied.local_id)
		first = false
	}
	undo.group_commit(&g)
	_project_inspectors_refresh()
	return true
}

// Duplicate as Asset: a copy of each selected sub-asset as a file of its own,
// beside the file that holds it and named after the sub-asset, where the
// sub-asset is a document. The file's unsaved edits are in the copy, and the
// file does not have to be open. The new files are selected. Like every file
// operation it is not an undo step. Returns whether the selection held a
// sub-asset.
project_ops_duplicate_as_asset :: proc() -> bool {
	subs := _project_selected_sub_assets()
	if len(subs) == 0 do return false
	made := make([dynamic]string, context.temp_allocator)
	for e in subs {
		ref, _, ok := _project_sub_ref(e.path, e.sub_id)
		source, found := subassets.get(ref)
		doc := inspector.asset_doc_get_ref(ref) if ok && found else nil
		if doc == nil || source.kind == "" {
			fmt.printf("[Editor] Duplicate: the importer of %s makes its sub-assets, they have no data of their own to copy\n", e.path)
			continue
		}
		// A sub-asset's name is free text, a file's is not.
		file, _ := strings.replace_all(source.name, "/", "_", context.temp_allocator)
		file, _ = strings.replace_all(file, ":", "_", context.temp_allocator)
		if file == "" do file = "Sub-Asset"
		dst := _project_unique_dest(filepath.dir(e.path), fmt.tprintf("%s.%s", file, source.kind))
		if !serialization.save_to_file(dst, doc.data) {
			fmt.printf("[Editor] Duplicate: failed to write %s\n", dst)
			continue
		}
		append(&made, dst)
	}
	asset_pipeline.asset_db_refresh()
	project_dir_cache_invalidate()
	_project_select_paths(made[:])
	_project_inspectors_refresh()
	return true
}

// Every asset delete (Edit/Delete, Assets/Delete, the Delete key) asks first.
// A file goes to the OS Trash and undo does not bring it back. A sub-asset
// leaves its file and undo restores it. The dialog lists what it deletes,
// _project_delete_confirmed does the work.
project_ops_delete :: proc() {
	if sel_proj_count() == 0 {
		fmt.println("[Editor] Delete: select files first")
		return
	}
	_project_delete_pending_clear()
	context.allocator = runtime.default_allocator()
	for e in sel_proj_entries() {
		if e.sub_id != 0 {
			// A sub-asset its file lets the user remove (subassets.Provider.remove).
			_, provider, ok := _project_sub_ref(e.path, e.sub_id)
			if !ok || provider.remove == nil {
				fmt.printf("[Editor] Delete: the importer of %s makes its sub-assets, they are not removed\n", e.path)
				continue
			}
			append(&_delete_pending_subs, Proj_Sel{path = strings.clone(e.path), sub_id = e.sub_id})
			continue
		}
		if project_path_is_protected(e.path) {
			fmt.printf("[Editor] Delete: %s is a package root — remove the package folder on disk to uninstall\n", e.path)
			continue
		}
		append(&_delete_pending, strings.clone(e.path))
	}
	files, subs := len(_delete_pending), len(_delete_pending_subs)
	if files + subs == 0 do return

	DELETE_LIST_MAX :: 10
	b := strings.builder_make(context.temp_allocator)
	listed := 0
	for p in _delete_pending {
		if listed == DELETE_LIST_MAX do break
		fmt.sbprintf(&b, "%s\n", p)
		listed += 1
	}
	for e in _delete_pending_subs {
		if listed == DELETE_LIST_MAX do break
		name := "?"
		if ref, _, ok := _project_sub_ref(e.path, e.sub_id); ok {
			if sub, found := subassets.get(ref); found do name = sub.name
		}
		fmt.sbprintf(&b, "%s / %s\n", e.path, name)
		listed += 1
	}
	if files + subs > listed do fmt.sbprintf(&b, "... and %d more\n", files + subs - listed)
	if files > 0 do strings.write_string(&b, "\nThe files move to the Trash. Undo does not restore them.")
	if subs > 0 {
		// One in an open file is an edit of that file. One in a file that is
		// not open is a change of the file on disk.
		open, closed := 0, 0
		for e in _delete_pending_subs {
			ref, _, ok := _project_sub_ref(e.path, e.sub_id)
			if ok && subassets.editable(ref.guid) do open += 1
			else do closed += 1
		}
		strings.write_string(&b, "\nThe sub-assets leave their files. A field that uses one shows it as missing.")
		if open > 0 && closed == 0 do strings.write_string(&b, " Undo restores them.")
		if open == 0 && closed > 0 do strings.write_string(&b, " Their files are not open, so undo does not restore them.")
		if open > 0 && closed > 0 do strings.write_string(&b, " Undo restores those of an open file, not the others.")
	}
	what := "sub-asset" if files == 0 else "asset"
	title := fmt.tprintf("Delete selected %s?", what) if files + subs == 1 else fmt.tprintf("Delete %d selected %ss?", files + subs, what)
	widgets.dialog_open({
		title       = title,
		description = strings.to_string(b),
		icon        = icons.ICON_MD_WARNING,
		buttons     = {
			{label = "Delete", action = _project_delete_confirmed, is_default = true},
			{label = "Cancel", action = _project_delete_pending_clear, is_cancel = true},
		},
	})
}

// What the open delete confirmation asks about: file paths, and sub-assets
// as (their file's path, their id). Default allocator: the lists live across
// frames.
@(private = "file")
_delete_pending: [dynamic]string
@(private = "file")
_delete_pending_subs: [dynamic]Proj_Sel

@(private = "file")
_project_delete_pending_clear :: proc() {
	context.allocator = runtime.default_allocator()
	for p in _delete_pending do delete(p)
	delete(_delete_pending)
	_delete_pending = nil
	for e in _delete_pending_subs do delete(e.path)
	delete(_delete_pending_subs)
	_delete_pending_subs = nil
}

// The paths an open delete confirmation would trash (tests).
project_ops_delete_pending :: proc() -> []string {
	return _delete_pending[:]
}

@(private = "file")
_project_delete_confirmed :: proc() {
	defer _project_delete_pending_clear()
	_project_delete_pending_sub_assets()
	if len(_delete_pending) == 0 do return
	for src in _delete_pending {
		if !os.exists(src) do continue // a trashed parent folder took it along
		if !file_move_to_trash(src) {
			fmt.printf("[Editor] Delete: failed to trash %s\n", src)
			continue
		}
		meta := strings.concatenate({src, ".meta"}, context.temp_allocator)
		if os.exists(meta) do file_move_to_trash(meta)
	}
	sel_proj_clear()
	_project_set_active("")
	asset_pipeline.asset_db_refresh()
	project_dir_cache_invalidate()
}

// Removes the sub-assets the confirmation asked about, as one undo step. A
// removed one leaves the selection, and its file is selected when nothing
// else is.
@(private = "file")
_project_delete_pending_sub_assets :: proc() {
	if len(_delete_pending_subs) == 0 do return
	g := undo.group_begin("Delete Sub-Assets")
	defer undo.group_end(&g)
	for e in _delete_pending_subs {
		ref, provider, ok := _project_sub_ref(e.path, e.sub_id)
		if !ok || provider.remove == nil || !provider.remove(ref) {
			fmt.printf("[Editor] Delete: a sub-asset of %s is not removed\n", e.path)
			continue
		}
		sel_proj_remove(e.path, e.sub_id)
		if sel_proj_count() == 0 do sel_proj_only(e.path)
	}
	undo.group_commit(&g)
	_project_inspectors_refresh()
}

// --- Menu registration ----------------------------------------------------------
// Assets/... items appear in the top menu AND the project right-click menu.

@(menu_item = {path = "Assets/Create/Folder", order = -20, shortcut = "", help = "Creates a folder in the Project window's open folder"})
project_menu_new_folder :: proc() {
	project_ops_new_folder()
}

@(menu_separator = {path = "Assets/Create", order = -15})
project_menu_folder_separator :: proc() {}

@(menu_separator = {path = "Assets", order = -90})
project_menu_ops_separator :: proc() {}

@(private)
_project_has_selection :: proc() -> bool {
	return projectWindowData.selectedFile != "" || keymap.disabled("No file is selected")
}

@(private)
_project_selection_renameable :: proc() -> bool {
	if path, sub, is_sub := _project_selected_sub(); is_sub {
		_, provider, ok := _project_sub_ref(path, sub)
		if !ok || provider.rename == nil do return keymap.disabled("The file's importer names this sub-asset")
		return true
	}
	sel := projectWindowData.selectedFile
	if sel == "" do return keymap.disabled("No file is selected")
	if project_path_is_protected(sel) do return keymap.disabled("The Assets and Packages roots and the package folders keep their names")
	return true
}

// Whether the selection's last entry is a sub-asset the inspector edits as a
// document: one with data of its own, which a copy can take. What shows
// Duplicate as Asset.
@(private)
_project_sub_asset_is_document :: proc() -> bool {
	path, sub, is_sub := _project_selected_sub()
	if !is_sub do return false
	_, provider, ok := _project_sub_ref(path, sub)
	return ok && provider.text != nil
}

@(private)
_project_can_duplicate_as_asset :: proc() -> bool {
	return _project_sub_asset_is_document() || keymap.disabled("Select a sub-asset that has data of its own: a scene's material, not a model's part")
}

@(menu_item = {path = "Assets/Reveal in Finder", order = -69, shortcut = "", help = "Shows the selected file in the OS file browser"})
project_menu_show_in_finder :: proc() {
	project_ops_show_in_finder()
}

@(menu_item = {path = "Assets/Open", order = -68, enabled = _project_has_selection, help = "Opens the selected file in the program the OS assigns to it"})
project_menu_open :: proc() {
	sel := projectWindowData.selectedFile
	if sel == "" do return
	file_open_in_os(sel)
}

@(menu_item = {path = "Assets/Delete", order = -67, enabled = _project_has_selection, help = "Asks, then moves the selected files to the Trash and removes the selected sub-assets from their files"})
project_menu_delete :: proc() {
	project_ops_delete()
}

@(menu_item = {path = "Assets/Rename", order = -66, enabled = _project_selection_renameable, help = "Renames the selected file or sub-asset"})
project_menu_rename :: proc() {
	_project_begin_rename_selected()
}

@(menu_item = {path = "Assets/Duplicate", order = -66, enabled = _project_has_selection, help = "Copies the selected files beside them. A selected sub-asset is copied inside the file that holds it"})
project_menu_duplicate :: proc() {
	project_ops_duplicate()
}

@(menu_item = {path = "Assets/Duplicate as Asset", order = -66, enabled = _project_can_duplicate_as_asset, visible = _project_sub_asset_is_document, help = "Copies the selected sub-asset into a file of its own, beside the file that holds it"})
project_menu_duplicate_as_asset :: proc() {
	project_ops_duplicate_as_asset()
}

@(menu_item = {path = "Assets/Copy Path", order = -65, enabled = _project_has_selection, help = "Copies the selected file's path"})
project_menu_copy_path :: proc() {
	sel := projectWindowData.selectedFile
	if sel == "" do return
	im.SetClipboardText(strings.clone_to_cstring(sel, context.temp_allocator))
}

@(private)
_project_selection_has_guid :: proc() -> bool {
	sel := projectWindowData.selectedFile
	if sel == "" do return keymap.disabled("No file is selected")
	_, ok := assets.asset_db_get_guid(sel)
	return ok || keymap.disabled("The selected file is not an asset")
}

@(menu_item = {path = "Assets/Copy GUID", order = -64, enabled = _project_selection_has_guid, help = "Copies the selected asset's GUID"})
project_menu_copy_uuid :: proc() {
	guid, ok := assets.asset_db_get_guid(projectWindowData.selectedFile)
	if !ok do return
	im.SetClipboardText(strings.clone_to_cstring(uuid.to_string(guid, context.temp_allocator), context.temp_allocator))
}

@(menu_separator = {path = "Assets", order = -60})
@(menu_item = {path = "Assets/Open Scene Additive", order = -55, ext = "scene", help = "Opens the selected scene beside the open ones"})
project_menu_open_scene_additive :: proc() {
	asset_pipeline.asset_open_additive(projectWindowData.selectedFile)
}
