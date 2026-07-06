package editor

// macOS Dock icon for the bare (non-bundled) editor binary. GLFW/raylib's
// SetWindowIcon is a no-op on macOS — the Dock icon normally comes from the
// .app bundle — but a running process may swap it via
// NSApplication.applicationIconImage. The _darwin file suffix scopes this to
// macOS builds; other platforms compile the stub in dock_icon_stub.odin.

import "base:intrinsics"
import NS "core:sys/darwin/Foundation"

@(private = "file")
msgSend :: intrinsics.objc_send

// Call after rl.InitWindow (NSApplication must exist). Accepts any image
// format NSImage reads (png included).
set_dock_icon :: proc(image_path: string) {
    app := NS.Application_sharedApplication()
    if app == nil do return
    ns_path := NS.String_initWithOdinString(NS.String_alloc(), image_path)
    img := msgSend(^NS.Image, NS.Image_alloc(), "initWithContentsOfFile:", ns_path)
    if img != nil {
        msgSend(nil, app, "setApplicationIconImage:", img)
    }
}
