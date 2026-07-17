package editor

// macOS file-manager integration for the project view: move-to-Trash
// (recoverable, Finder-native — never a permanent delete) and reveal-in-
// Finder. Same objc pattern as dock_icon_darwin.odin; other platforms
// compile project_os_stub.odin.

import "base:intrinsics"
import "core:path/filepath"
import NS "core:sys/darwin/Foundation"

@(private = "file")
msgSend :: intrinsics.objc_send

// Minimal local bindings for classes core Foundation doesn't wrap. The
// attribute resolves the class at runtime — NSWorkspace lives in AppKit,
// which is already loaded via NSApplication.
@(objc_class = "NSFileManager")
FileManager :: struct {
	using _: NS.Object,
}

@(objc_class = "NSWorkspace")
Workspace :: struct {
	using _: NS.Object,
}

// Moves the file/folder into the user's Trash.
file_move_to_trash :: proc(path: string) -> bool {
	fm := msgSend(^FileManager, FileManager, "defaultManager")
	if fm == nil do return false
	// Project paths are cwd-relative; AppKit path APIs need absolute ones.
	abs, abs_err := filepath.abs(path, context.temp_allocator)
	if abs_err != nil do return false
	ns_path := NS.String_initWithOdinString(NS.String_alloc(), abs)
	url := NS.URL_initFileURLWithPath(NS.URL_alloc(), ns_path)
	if url == nil do return false
	return bool(msgSend(NS.BOOL, fm, "trashItemAtURL:resultingItemURL:error:", url, rawptr(nil), rawptr(nil)))
}

// Reveals (selects) the file/folder in Finder.
file_reveal_in_os :: proc(path: string) -> bool {
	ws := msgSend(^Workspace, Workspace, "sharedWorkspace")
	if ws == nil do return false
	// Finder needs an ABSOLUTE path — a relative one selects nothing and
	// Finder falls back to an arbitrary window.
	abs, abs_err := filepath.abs(path, context.temp_allocator)
	if abs_err != nil do return false
	ns_path := NS.String_initWithOdinString(NS.String_alloc(), abs)
	empty := NS.String_initWithOdinString(NS.String_alloc(), "")
	return bool(msgSend(NS.BOOL, ws, "selectFile:inFileViewerRootedAtPath:", ns_path, empty))
}
