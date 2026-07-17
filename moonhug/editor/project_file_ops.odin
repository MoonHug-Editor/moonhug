package editor

// Project-view file operations: New Folder, Show in Finder and Delete are
// Assets/... menu items (appearing in BOTH the top Assets menu and the
// project view's right-click menu — Unity puts only these in the context
// menu). Cut/Copy/Paste/Duplicate are shortcut-only, like Finder:
// cmd+C/X/V/D and cmd+Backspace in _project_handle_list_keys.
//
// Guid rules (the part that keeps references alive):
// - Cut/Paste MOVES the .meta with the asset — same asset, new path, guid
//   preserved, references survive (mirrors rename).
// - Copy/Paste and Duplicate never copy .meta — the copy is a NEW asset and
//   mints a fresh guid on refresh.
// - Delete trashes the .meta with the asset (recoverable together).
//
// Deletes go to the OS Trash (project_os_darwin.odin), never permanent.
// File operations are NOT undoable (see docs/Undo.md non-goals).

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import strings "core:strings"
import engine "../engine"

// --- File clipboard -----------------------------------------------------------

@(private = "file")
_file_clip: [dynamic]string // owned clones

@(private = "file")
_file_clip_cut: bool

project_file_ops_shutdown :: proc() {
	for p in _file_clip do delete(p)
	delete(_file_clip)
	_file_clip = nil
}

// Cut files draw dimmed in the list (Finder/Explorer convention).
project_file_is_cut :: proc(path: string) -> bool {
	if !_file_clip_cut do return false
	for p in _file_clip {
		if p == path do return true
	}
	return false
}

@(private = "file")
_file_clip_set :: proc(cut: bool) {
	for p in _file_clip do delete(p)
	clear(&_file_clip)
	_file_clip_cut = cut
	for p in sel_proj_items() {
		append(&_file_clip, strings.clone(p))
	}
}

// --- Op helpers ---------------------------------------------------------------

// dir/name, or dir/"name N" when taken (extension preserved for files).
@(private = "file")
_project_unique_dest :: proc(dir, name: string) -> string {
	dst, _ := filepath.join({dir, name}, context.temp_allocator)
	if !os.exists(dst) do return dst
	stem := filepath.stem(name)
	ext := filepath.ext(name) // "" for folders, ".mat" style for files
	for i in 1 ..< 1000 {
		cand, _ := filepath.join({dir, fmt.tprintf("%s %d%s", stem, i, ext)}, context.temp_allocator)
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
	_project_scroll_to_list_sel = true
}

// --- Operations (menu items + shortcuts call these) ----------------------------

project_ops_new_folder :: proc() {
	dir := projectViewData.currentPath
	if dir == "" do return
	dst := _project_unique_dest(dir, "New Folder")
	if os.make_directory(dst) != nil {
		fmt.printf("[Editor] New Folder: failed to create %s\n", dst)
		return
	}
	engine.asset_db_refresh()
	_project_set_selected(dst)
	_project_begin_rename(dst, false)
}

project_ops_show_in_finder :: proc() {
	target := projectViewData.selectedFile
	if target == "" do target = projectViewData.currentPath
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

project_ops_paste :: proc() {
	if len(_file_clip) == 0 {
		fmt.println("[Editor] Paste: clipboard is empty (Cut or Copy files first)")
		return
	}
	dst_dir := projectViewData.currentPath
	if dst_dir == "" do return

	pasted := make([dynamic]string, context.temp_allocator)
	for src in _file_clip {
		if !os.exists(src) do continue
		if _file_clip_cut {
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
	if _file_clip_cut {
		// A cut clipboard is one-shot (Finder/Explorer semantics).
		for p in _file_clip do delete(p)
		clear(&_file_clip)
		_file_clip_cut = false
	}
	engine.asset_db_refresh()
	_project_select_paths(pasted[:])
}

project_ops_duplicate :: proc() {
	srcs := slice.clone(sel_proj_items(), context.temp_allocator)
	if len(srcs) == 0 {
		fmt.println("[Editor] Duplicate: select files first")
		return
	}
	dups := make([dynamic]string, context.temp_allocator)
	for src in srcs {
		if !os.exists(src) do continue
		dst := _project_unique_dest(filepath.dir(src), filepath.base(src))
		if _project_copy_recursive(src, dst) do append(&dups, dst)
	}
	engine.asset_db_refresh()
	_project_select_paths(dups[:])
}

project_ops_delete :: proc() {
	srcs := slice.clone(sel_proj_items(), context.temp_allocator)
	if len(srcs) == 0 {
		fmt.println("[Editor] Delete: select files first")
		return
	}
	for src in srcs {
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
	engine.asset_db_refresh()
}

// --- Menu registration ----------------------------------------------------------
// Assets/... items appear in the top menu AND the project right-click menu.

@(menu_item = {path = "Assets/Create/Folder", order = -20, shortcut = ""})
project_menu_new_folder :: proc() {
	project_ops_new_folder()
}

@(menu_separator = {path = "Assets/Create", order = -15})
project_menu_folder_separator :: proc() {}

// Unity's project context grouping: Create | Show in Finder, Delete |
// tools (Extract...). The Create submenu is pinned first via top_order in
// main.odin; orders -68/-66 stay free for future Open/Rename items.
@(menu_separator = {path = "Assets", order = -90})
project_menu_ops_separator :: proc() {}

@(menu_item = {path = "Assets/Show in Finder", order = -69, shortcut = ""})
project_menu_show_in_finder :: proc() {
	project_ops_show_in_finder()
}

@(menu_item = {path = "Assets/Delete", order = -67, shortcut = ""})
project_menu_delete :: proc() {
	project_ops_delete()
}
