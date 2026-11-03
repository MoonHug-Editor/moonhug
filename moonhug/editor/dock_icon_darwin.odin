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

// The application menu's title, the bold name beside the Apple menu. For
// the bare binary macOS takes it from the process name, so the version is
// put there by hand. The menu bar reads the title when the main menu is
// set, so the menu is set again.
set_app_menu_title :: proc(title: string) {
    app := NS.Application_sharedApplication()
    if app == nil do return
    main_menu := msgSend(^NS.Menu, app, "mainMenu")
    if main_menu == nil do return
    app_item := msgSend(^NS.MenuItem, main_menu, "itemAtIndex:", NS.Integer(0))
    if app_item == nil do return
    app_menu := msgSend(^NS.Menu, app_item, "submenu")
    if app_menu == nil do return
    ns_title := NS.String_initWithOdinString(NS.String_alloc(), title)
    msgSend(nil, app_menu, "setTitle:", ns_title)
    msgSend(nil, app, "setMainMenu:", main_menu)
}
