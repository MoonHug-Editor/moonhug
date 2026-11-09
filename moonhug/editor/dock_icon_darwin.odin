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

// SDL's default menu bar has a Window menu whose Close item carries Cmd+W,
// and the key equivalent fires performClose on the window before any key
// event reaches imgui: Cmd+W would quit the editor. The editor's Window
// keymap uses Ctrl+W (Cmd+W here) to close the focused window, so the item
// loses its key. Quit stays Cmd+Q, and the window's close button works.
drop_window_close_key :: proc() {
    app := NS.Application_sharedApplication()
    if app == nil do return
    main_menu := msgSend(^NS.Menu, app, "mainMenu")
    if main_menu == nil do return
    empty := NS.String_initWithOdinString(NS.String_alloc(), "")
    count := msgSend(NS.Integer, main_menu, "numberOfItems")
    for i in 0 ..< count {
        top := msgSend(^NS.MenuItem, main_menu, "itemAtIndex:", i)
        if top == nil do continue
        sub := msgSend(^NS.Menu, top, "submenu")
        if sub == nil do continue
        n := msgSend(NS.Integer, sub, "numberOfItems")
        for j in 0 ..< n {
            item := msgSend(^NS.MenuItem, sub, "itemAtIndex:", j)
            if item == nil do continue
            key := msgSend(^NS.String, item, "keyEquivalent")
            if key != nil && NS.String_odinString(key) == "w" {
                msgSend(nil, item, "setKeyEquivalent:", empty)
            }
        }
    }
}
