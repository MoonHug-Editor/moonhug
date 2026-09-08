package app

// In-game demo hub on mhgui. The static part is authored in menu.scene: a
// canvas, a List node with a vertical LayoutGroup and the title row; the
// DemoMenu component points at the List. At play one Text row per scene
// authored on the component is created under the List, labels from the
// asset paths, each a Button (mhgui) over its Text. A click or the number
// key (1..9) loads that scene additively and hides the menu root (camera
// included); the loaded scene gets a small HUD canvas of its own with the
// ESC hint, itself a Button, and ESC or that click unloads it back to the
// menu. A per-frame update, so it
// runs in the app and under the editor's Simulate alike.

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:encoding/uuid"
import input "moonhug:engine/input"
import "moonhug:engine"
import mhgui "moonhug:packages/mhgui"
import text "moonhug:packages/text"

@(private = "file") _current_demo: ^engine.Scene
@(private = "file") _hud_back: ^mhgui.Button // "ESC: back to menu" in the running demo's scene
@(private = "file") _hud_hint: ^text.Text    // the F3 line under it
@(private = "file") _hud_colliders: bool     // what the hint last said about F3
@(private = "file") _rows: [dynamic]^mhgui.Button // one per demo, in menu.demos order; alive while the first row's node is

@(private = "file") _WHITE :: [4]f32{0.96, 0.96, 0.96, 1}
@(private = "file") _LIST_WIDTH :: f32(600)

@(update={order=2})
demo_menu_tick :: proc(dt: f32) {
    menu := demo_menu_get()
    if menu == nil do return
    // Rows live in the scene, so they vanish with a reload or a Simulate stop
    // (the world is restored); their absence is the signal to build again.
    if len(_rows) == 0 || engine.pool_get(&engine.ctx_world().transforms, engine.Handle(_rows[0].owner)) == nil {
        _menu_build(menu)
    }
    // The demo can go away under the menu (a Simulate stop unloads what the
    // run loaded): then the menu is back to its list.
    if _current_demo != nil && !engine.sm_scene_is_loaded(_current_demo) {
        _current_demo = nil
        _hud_back = nil
        _hud_hint = nil
        _menu_root_set_active(menu, true)
    }

    if _current_demo != nil {
        _hud_update()
        if input.key_released(.ESCAPE) || (_hud_back != nil && mhgui.button_clicked(_hud_back)) {
            engine.sm_scene_unload(_current_demo)
            _current_demo = nil
            _hud_back = nil
            _hud_hint = nil
            _menu_root_set_active(menu, true)
        }
        return
    }

    for guid, i in menu.demos {
        if i >= 9 do break // number keys only reach 9
        path, ok := engine.asset_db_get_path(uuid.Identifier(guid))
        // The row's button, or the number key. Key UP, so the press doesn't
        // leak into the loaded demo (a click is a release already).
        clicked := i < len(_rows) && mhgui.button_clicked(_rows[i])
        if ok && (clicked || input.key_released(input.Key(int(input.Key._1) + i))) {
            _current_demo = engine.scene_load_additive_path(path)
            if _current_demo != nil {
                scene_loaded()
                _hud_build(_current_demo)
                // Hide the menu scene (incl. its camera) while a demo runs.
                _menu_root_set_active(menu, false)
            }
        }
    }
}

// One row per scene under the authored List (its LayoutGroup lays them out
// below the title).
@(private = "file")
_menu_build :: proc(menu: ^DemoMenu) {
    clear(&_rows)
    _current_demo = nil // a rebuild means the scene was reloaded or restored: nothing of the run is left
    _hud_back = nil
    _hud_hint = nil
    list := engine.Transform_Handle(menu.list.handle)
    if engine.pool_get(&engine.ctx_world().transforms, engine.Handle(list)) == nil do return
    for guid, i in menu.demos {
        if i >= 9 do break
        path, ok := engine.asset_db_get_path(uuid.Identifier(guid))
        label := filepath.short_stem(filepath.base(path)) if ok else "(missing scene)"
        append(&_rows, _ui_text_button(list, fmt.tprintf("%d: %s", i + 1, label)))
    }
}

// The running demo's HUD lives in ITS scene, so it goes away with it and
// stays while the menu root is hidden. Above the demo's own canvases.
@(private = "file")
_hud_build :: proc(scene: ^engine.Scene) {
    canvas := _ui_canvas("Menu HUD", engine.Transform_Handle(scene.root.handle), 100)
    engine.transform_add_comp(canvas, .GraphicRaycaster) // add_comp resets: reversed graphics ignored
    // A column like the menu's: the back button, the F3 line under it.
    column := _ui_node("HUD", canvas, {_LIST_WIDTH, 60})
    _, rt := engine.transform_get_comp(column, engine.RectTransform)
    rt.anchor_min = {0, 1}
    rt.anchor_max = {0, 1}
    rt.pivot = {0, 1}
    rt.anchored_position = {10, -10, 0}
    _, lgp := engine.transform_add_comp(column, .LayoutGroup)
    lg := cast(^mhgui.LayoutGroup)lgp
    lg.direction = .Vertical
    lg.spacing = {0, 4}
    _hud_back = _ui_text_button(column, "ESC: back to menu")
    _hud_hint = _ui_text(column, "", {_LIST_WIDTH, 26}, 20)
    _hud_colliders = !engine.debug_draw_enabled // forces the first update to write
    _hud_update()
}

@(private = "file")
_hud_update :: proc() {
    if _hud_hint == nil || _hud_colliders == engine.debug_draw_enabled do return
    _hud_colliders = engine.debug_draw_enabled
    _set_text(_hud_hint, "F3: colliders (on)" if _hud_colliders else "")
}

// --- Building blocks -----------------------------------------------------------------

@(private = "file")
_ui_canvas :: proc(name: string, parent: engine.Transform_Handle, sort_order: i32) -> engine.Transform_Handle {
    tH := engine.transform_new(name, parent)
    _, cp := engine.transform_add_comp(tH, .Canvas)
    (cast(^engine.Canvas)cp).sort_order = sort_order
    return tH
}

// A rect with a CanvasRenderer, centered by default.
@(private = "file")
_ui_node :: proc(name: string, parent: engine.Transform_Handle, size: [2]f32) -> engine.Transform_Handle {
    tH := engine.transform_new(name, parent)
    _, rtp := engine.transform_add_comp(tH, .RectTransform)
    (cast(^engine.RectTransform)rtp).size_delta = size
    engine.transform_add_comp(tH, .CanvasRenderer)
    return tH
}

@(private = "file")
_ui_text :: proc(parent: engine.Transform_Handle, label: string, size: [2]f32, font_size: f32) -> ^text.Text {
    tH := _ui_node(label, parent, size)
    _, txp := engine.transform_add_comp(tH, .Text)
    tx := cast(^text.Text)txp
    tx.text = strings.clone(label) // the component owns its string (cleanup_Text)
    tx.font = text.default_font_guid()
    tx.material = text.default_material_guid()
    tx.font_size = font_size
    tx.color = _WHITE
    return tx
}

// A menu row: a Text that is also a Button. The Text is the button's graphic,
// hit through raycast_target and tinted through its CanvasRenderer.
@(private = "file")
_ui_text_button :: proc(parent: engine.Transform_Handle, label: string) -> ^mhgui.Button {
    row := _ui_text(parent, label, {_LIST_WIDTH, 26}, 20)
    _, bp := engine.transform_add_comp(row.owner, .Button)
    b := cast(^mhgui.Button)bp
    b.colors.highlighted = {1, 0.9, 0.5, 1}
    b.colors.pressed = {1, 0.75, 0.3, 1}
    b.colors.selected = {1, 1, 1, 1}
    return b
}

@(private = "file")
_set_text :: proc(tx: ^text.Text, s: string) {
    delete(tx.text)
    tx.text = strings.clone(s)
}

demo_menu_get :: proc() -> ^DemoMenu {
    it := engine.pool_iterator(demo_menus(engine.ctx_world()))
    for m, _ in engine.pool_next(&it) {
        if m.enabled do return m
    }
    return nil
}

@(private = "file")
_menu_root_set_active :: proc(menu: ^DemoMenu, active: bool) {
    w := engine.ctx_world()
    t := engine.pool_get(&w.transforms, engine.Handle(menu.owner))
    if t != nil do t.is_active = active
}
