package editor

// Samples section of the package inspector (docs/Plugins.md). A sample lives
// in packages/<pkg>/samples/<sample> and installs as a SIBLING package:
// - Copy: packages/<pkg>/samples/<sample> -> packages/<sample>, .meta files
//   included — a sample ships pre-authored assets whose guids must survive
//   the copy (the opposite of Copy/Paste, which mints fresh guids).
// - Symlink: packages/<sample> -> <pkg>/samples/<sample> (relative, so the
//   repo stays relocatable) — live-editing mode, edits land in the source.
// Assets mount immediately via refresh; CODE compiles on the next
// prebuild + rebuild (run.sh), same as any package install.
//
// Remove asks confirmation: a copied install may carry user edits, so the
// folder goes to the OS Trash (project convention); a symlink is just
// unlinked — the source stays.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "inspector"
import "../engine"

Sample_State :: enum {
	Not_Installed,
	Copied, // packages/<sample> is a real directory
	Linked, // packages/<sample> is a symlink
}

Package_Sample :: struct {
	name:  string, // temp
	src:   string, // temp; packages/<pkg>/samples/<name>
	dst:   string, // temp; packages/<name>
	state: Sample_State,
}

// Pending remove confirmation (owned clones, one at a time).
@(private = "file")
_sample_confirm_name: string
@(private = "file")
_sample_confirm_dst: string
@(private = "file")
_sample_confirm_linked: bool

project_package_samples_shutdown :: proc() {
	delete(_sample_confirm_name)
	delete(_sample_confirm_dst)
	_sample_confirm_name = ""
	_sample_confirm_dst = ""
}

// Temp-allocated. Presence of packages/<name> = installed (docs/Plugins.md
// install model — the editor only ever sees a directory).
package_samples_list :: proc(pkg: string) -> []Package_Sample {
	samples_dir := fmt.tprintf("%s/%s/samples", _PROJECT_PACKAGES_PATH, pkg)
	entries, ok := project_dir_listing(samples_dir)
	if !ok do return nil
	out := make([dynamic]Package_Sample, context.temp_allocator)
	for entry in entries {
		if !entry.is_dir do continue
		if strings.has_prefix(entry.name, ".") do continue
		dst := fmt.tprintf("%s/%s", _PROJECT_PACKAGES_PATH, entry.name)
		state := Sample_State.Not_Installed
		if info, lerr := os.lstat(dst, context.temp_allocator); lerr == nil {
			state = info.type == .Symlink ? .Linked : .Copied
		}
		append(&out, Package_Sample{
			name  = strings.clone(entry.name, context.temp_allocator),
			src   = fmt.tprintf("%s/%s", samples_dir, entry.name),
			dst   = dst,
			state = state,
		})
	}
	return out[:]
}

// Recursive copy KEEPING .meta files — sample guids are committed with the
// package and must be identical in every install (docs/Plugins.md#Assets).
@(private = "file")
_sample_copy_recursive :: proc(src, dst: string) -> bool {
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
			if strings.has_prefix(entry.name, ".") do continue
			sub_src, _ := filepath.join({src, entry.name}, context.temp_allocator)
			sub_dst, _ := filepath.join({dst, entry.name}, context.temp_allocator)
			if !_sample_copy_recursive(sub_src, sub_dst) do ok = false
		}
		return ok
	}
	data, rerr := os.read_entire_file(src, context.temp_allocator)
	if rerr != nil do return false
	return os.write_entire_file(dst, data) == nil
}

@(private = "file")
_sample_after_change :: proc(verb, name: string) {
	engine.asset_db_refresh()
	project_dir_cache_invalidate()
	fmt.printf("[Editor] %s sample %s - code changes need a prebuild + rebuild (run.sh)\n", verb, name)
}

// Installs never overwrite: anything already at the destination (a stale
// link, a same-named package) fails loudly instead of nesting into it.
@(private = "file")
_sample_dst_taken :: proc(s: Package_Sample) -> bool {
	if _, lerr := os.lstat(s.dst, context.temp_allocator); lerr == nil {
		fmt.printf("[Editor] Install sample: %s already exists - remove it first\n", s.dst)
		return true
	}
	return false
}

@(private = "file")
_sample_install_copy :: proc(s: Package_Sample) {
	if _sample_dst_taken(s) do return
	if !_sample_copy_recursive(s.src, s.dst) {
		fmt.printf("[Editor] Install sample: copy %s -> %s failed\n", s.src, s.dst)
		return
	}
	_sample_after_change("Installed", s.name)
}

@(private = "file")
_sample_install_link :: proc(s: Package_Sample) {
	if _sample_dst_taken(s) do return
	// Both live under packages/, so the relative target is just the
	// source path with the "packages/" prefix dropped.
	target := s.src[len(_PROJECT_PACKAGES_PATH) + 1:]
	if err := os.symlink(target, s.dst); err != nil {
		fmt.printf("[Editor] Install sample: symlink %s -> %s failed: %v\n", s.dst, target, err)
		return
	}
	_sample_after_change("Linked", s.name)
}

@(private = "file")
_sample_remove_confirmed :: proc() {
	if _sample_confirm_linked {
		if err := os.remove(_sample_confirm_dst); err != nil {
			fmt.printf("[Editor] Remove sample: unlink %s failed: %v\n", _sample_confirm_dst, err)
			return
		}
	} else if !file_move_to_trash(_sample_confirm_dst) {
		fmt.printf("[Editor] Remove sample: failed to trash %s\n", _sample_confirm_dst)
		return
	}
	_sample_after_change("Removed", _sample_confirm_name)
}

// The inspector package can't import the editor root (cycle), so the editor
// injects the samples section. Assigning a proc pointer is order-free, so
// @(init) keeps the wiring here with the feature instead of in editor init.
@(init)
_package_samples_hook :: proc "contextless" () {
	inspector.package_samples_draw = package_samples_draw
}

// Drawn by the package inspector.
package_samples_draw :: proc(pkg: string) {
	samples := package_samples_list(pkg)
	if len(samples) == 0 do return

	im.SeparatorText("Samples")
	style := im.GetStyle()
	btn_w :: proc(label: cstring) -> f32 {
		return im.CalcTextSize(label).x + im.GetStyle().FramePadding.x * 2
	}

	for s in samples {
		im.PushID(strings.clone_to_cstring(s.name, context.temp_allocator))
		defer im.PopID()

		im.AlignTextToFramePadding() // row text lines up with the buttons
		im.Text(strings.clone_to_cstring(s.name, context.temp_allocator))

		// Controls anchor to the RIGHT edge: shift the cursor so exactly
		// their width remains.
		w: f32
		switch s.state {
		case .Copied, .Linked:
			icon: cstring = s.state == .Linked ? ICON_MD_LINK : ICON_MD_FOLDER_CHECK
			w = im.CalcTextSize(icon).x + style.ItemSpacing.x + btn_w("Remove")
			im.SameLine()
			im.SetCursorPosX(im.GetCursorPosX() + im.GetContentRegionAvail().x - w)
			im.TextDisabled(icon)
			im.SameLine()
			if im.Button("Remove") {
				delete(_sample_confirm_name)
				delete(_sample_confirm_dst)
				_sample_confirm_name = strings.clone(s.name)
				_sample_confirm_dst = strings.clone(s.dst)
				_sample_confirm_linked = s.state == .Linked
				im.OpenPopup("Remove Sample")
			}
			_sample_draw_confirm_popup()
		case .Not_Installed:
			w = btn_w("Copy") + style.ItemSpacing.x + btn_w("Symlink")
			im.SameLine()
			im.SetCursorPosX(im.GetCursorPosX() + im.GetContentRegionAvail().x - w)
			if im.Button("Copy") do _sample_install_copy(s)
			im.SameLine()
			if im.Button("Symlink") do _sample_install_link(s)
		}
	}
}

// Inside the row's PushID scope, so OpenPopup and BeginPopupModal agree on
// the popup's ID.
@(private = "file")
_sample_draw_confirm_popup :: proc() {
	center := im.GetMainViewport().Pos + im.GetMainViewport().Size * 0.5
	im.SetNextWindowPos(center, .Appearing, im.Vec2{0.5, 0.5})
	if im.BeginPopupModal("Remove Sample", nil, {.AlwaysAutoResize}) {
		im.Text(strings.clone_to_cstring(fmt.tprintf("Remove sample '%s'?", _sample_confirm_name), context.temp_allocator))
		if _sample_confirm_linked {
			im.TextDisabled("The symlink is removed - the sample source stays.")
		} else {
			im.TextDisabled(strings.clone_to_cstring(fmt.tprintf("%s moves to the Trash.", _sample_confirm_dst), context.temp_allocator))
		}
		if im.Button("Remove", im.Vec2{100, 0}) {
			_sample_remove_confirmed()
			im.CloseCurrentPopup()
		}
		im.SameLine()
		if im.Button("Cancel", im.Vec2{100, 0}) {
			im.CloseCurrentPopup()
		}
		im.EndPopup()
	}
}
