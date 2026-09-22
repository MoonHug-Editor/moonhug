package tests

// Debug tooltips (editor/widgets/ui_debug_tooltips.odin) rest on two
// conventions nothing enforces at compile time. Both fail silently: the
// element just shows nothing, or "built-in" instead of its attribute. These
// tests make them fail here instead.
//
// SCOPE is what the editor compiles, not the disk: the prebuild's scan roots
// and the installed packages, symlinks followed, `external/` and hidden dirs
// skipped, only files that import imgui. A library dropped elsewhere in the
// repo is never read, and a plugin is checked exactly because it is linked
// into the editor, which is when a raw tooltip would go dark.

import "core:os"
import "core:strings"
import "core:testing"

// Mirrors prebuild.SCAN_ROOTS plus PACKAGES_DIR. Kept literal here: the
// prebuild is a separate program and cannot be imported.
_CONTRACT_ROOTS := []string{"moonhug/editor", "moonhug/engine", "moonhug/engine_editor", "moonhug/packages"}

// A call that truly cannot go through widgets.tooltip carries this on the
// line above. None today, so every use is visible in review.
_RAW_TOOLTIP_OK :: "debug-tooltips: raw ok"

@(test)
test_no_raw_imgui_tooltips :: proc(t: ^testing.T) {
	files := make([dynamic]string, context.temp_allocator)
	for root in _CONTRACT_ROOTS do _collect_odin_files(root, &files)
	testing.expect(t, len(files) > 100, "the walk should see the editor's sources")

	for path in files {
		data, rerr := os.read_entire_file(path, context.temp_allocator)
		if rerr != nil do continue
		text := string(data)
		if !strings.contains(text, "odin-imgui") do continue
		if strings.has_suffix(path, "/ui_debug_tooltips.odin") do continue
		lines := strings.split_lines(text, context.temp_allocator)
		for line, i in lines {
			if !strings.contains(line, "im.SetTooltip(") && !strings.contains(line, "im.SetItemTooltip(") do continue
			if strings.has_prefix(strings.trim_space(line), "//") do continue
			if i > 0 && strings.contains(lines[i - 1], _RAW_TOOLTIP_OK) do continue
			testing.expectf(t, false, "%s:%d calls imgui's tooltip directly — use widgets.tooltip so debug tooltips can name the element", path, i + 1)
		}
	}
}

// Every registration the generators emit for a UI element carries its origin.
// Checked on the generated files themselves, so nothing outside the prebuild's
// output can match. A generator that forgets shows up on the next build.
@(test)
test_generated_ui_registrations_carry_origin :: proc(t: ^testing.T) {
	REGISTRATIONS := []string{
		"menu.add_menu_item(", "menu.add_menu_toggle(",
		"view_menu_add_action(", "view_menu_add_toggle(", "view_tab_bar_add_item(",
		"toolbar_add_item(", "overlay_add_item(", "settings_add_tab(",
		"__wnd.register(",
	}
	files := make([dynamic]string, context.temp_allocator)
	_collect_odin_files("moonhug/editor", &files)
	seen := 0
	for path in files {
		if !strings.has_suffix(path, "_generated.odin") do continue
		data, rerr := os.read_entire_file(path, context.temp_allocator)
		if rerr != nil do continue
		for line, i in strings.split_lines(string(data), context.temp_allocator) {
			for reg in REGISTRATIONS {
				if !strings.contains(line, reg) do continue
				seen += 1
				testing.expectf(t, strings.contains(line, "origin = "), "%s:%d registers a UI element without origin=", path, i + 1)
			}
		}
	}
	testing.expect(t, seen > 100, "the generated registrations should be found")
}

// Recursive, symlinks followed (samples install as symlinked packages),
// hidden dirs, `external` and `tests` skipped.
_collect_odin_files :: proc(dir: string, out: ^[dynamic]string) {
	handle, oerr := os.open(dir)
	if oerr != nil do return
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	os.close(handle)
	if rerr != nil do return
	for e in entries {
		if strings.has_prefix(e.name, ".") || e.name == "external" do continue
		full := strings.concatenate({dir, "/", e.name}, context.temp_allocator)
		if e.type == .Directory || (e.type == .Symlink && os.is_dir(full)) {
			_collect_odin_files(full, out)
		} else if strings.has_suffix(e.name, ".odin") {
			append(out, full)
		}
	}
}
