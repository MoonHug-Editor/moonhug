package app

// In-game demo hub on mhgui. The static part is authored in menu.scene: a
// canvas, a List node with a vertical LayoutGroup and the title row; the
// DemoMenu component points at the List. At play one Text row per scene
// authored on the component is created under the List, labels from the
// asset paths. A number key (1..9) loads that scene additively and hides the
// menu root (camera included); the loaded scene gets a small HUD canvas of
// its own with the ESC hint, and ESC unloads it back to the menu. A
// per-frame update, so it runs in the app and under the editor's Simulate
// alike.

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:encoding/uuid"
import input "moonhug:engine/input"
import "moonhug:engine"
import text "moonhug:packages/text"

@(private = "file") _current_demo: ^engine.Scene
@(private = "file") _hud: ^text.Text     // the ESC hint in the running demo's scene
@(private = "file") _hud_colliders: bool // what the hint last said about F3
@(private = "file") _first_row: engine.Transform_Handle // the rows exist while this node does

@(private = "file") _WHITE :: [4]f32{0.96, 0.96, 0.96, 1}
@(private = "file") _LIST_WIDTH :: f32(600)

@(update={order=2})
demo_menu_tick :: proc(dt: f32) {
    menu := demo_menu_get()
    if menu == nil do return
    // Rows live in the scene, so they vanish with a reload or a Simulate stop
    // (the world is restored); their absence is the signal to build again.
    if engine.pool_get(&engine.ctx_world().transforms, engine.Handle(_first_row)) == nil {
        _menu_build(menu)
    }

    if _current_demo != nil {
        _hud_update()
        if input.key_released(.ESCAPE) {
            engine.sm_scene_unload(_current_demo)
            _current_demo = nil
            _hud = nil
            _menu_root_set_active(menu, true)
        }
        return
    }

    for guid, i in menu.demos {
        if i >= 9 do break // number keys only reach 9
        path, ok := engine.asset_db_get_path(uuid.Identifier(guid))
        // React on key UP so the press doesn't leak into the loaded demo.
        if ok && input.key_released(input.Key(int(input.Key._1) + i)) {
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
    _first_row = {}
    list := engine.Transform_Handle(menu.list.handle)
    if engine.pool_get(&engine.ctx_world().transforms, engine.Handle(list)) == nil do return
    for guid, i in menu.demos {
        if i >= 9 do break
        path, ok := engine.asset_db_get_path(uuid.Identifier(guid))
        label := filepath.short_stem(filepath.base(path)) if ok else "(missing scene)"
        row := _ui_text(list, fmt.tprintf("%d: %s", i + 1, label), {_LIST_WIDTH, 26}, 20)
        if i == 0 do _first_row = row.owner
    }
}

// The running demo's HUD lives in ITS scene, so it goes away with it and
// stays while the menu root is hidden. Above the demo's own canvases.
@(private = "file")
_hud_build :: proc(scene: ^engine.Scene) {
    canvas := _ui_canvas("Menu HUD", engine.Transform_Handle(scene.root.handle), 100)
    _hud = _ui_text(canvas, "", {_LIST_WIDTH, 60}, 20)
    _, rt := engine.transform_get_comp(_hud.owner, engine.RectTransform)
    rt.anchor_min = {0, 1}
    rt.anchor_max = {0, 1}
    rt.pivot = {0, 1}
    rt.anchored_position = {10, -10, 0}
    _hud_colliders = !engine.debug_draw_enabled // forces the first update to write
    _hud_update()
}

@(private = "file")
_hud_update :: proc() {
    if _hud == nil || _hud_colliders == engine.debug_draw_enabled do return
    _hud_colliders = engine.debug_draw_enabled
    _set_text(_hud, "ESC: back to menu\nF3: colliders (on)" if _hud_colliders else "ESC: back to menu")
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
