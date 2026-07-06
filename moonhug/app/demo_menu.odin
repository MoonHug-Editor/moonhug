package app

// In-game demo hub: lists the scenes authored on the DemoMenu component and
// loads one additively on its number key (1..9); ESC unloads it back to the
// menu. Draws with plain raylib, so demo_menu_draw must run inside the
// BeginDrawing/EndDrawing block (called from main after world rendering).

import "core:path/filepath"
import "core:strings"
import "core:encoding/uuid"
import rl "vendor:raylib"
import "../engine"

@(private = "file")
_current_demo: ^engine.Scene

demo_menu_draw :: proc() {
    menu := demo_menu_get()
    if menu == nil do return

    if _current_demo != nil {
        rl.DrawText("ESC: back to menu", 10, 10, 20, rl.RAYWHITE)
        if rl.IsKeyReleased(.ESCAPE) {
            engine.sm_scene_unload(_current_demo)
            _current_demo = nil
            _menu_root_set_active(menu, true)
        }
        return
    }

    rl.DrawText("DEMOS", 10, 10, 30, rl.RAYWHITE)
    y: i32 = 50
    for guid, i in menu.demos {
        if i >= 9 do break // number keys only reach 9
        path, ok := engine.asset_db_get_path(uuid.Identifier(guid))
        label := filepath.short_stem(filepath.base(path)) if ok else "(missing scene)"
        line := strings.clone_to_cstring(
            strings.concatenate({_DIGITS[i], ": ", label}, context.temp_allocator),
            context.temp_allocator,
        )
        rl.DrawText(line, 10, y, 20, rl.RAYWHITE)
        y += 26

        // React on key UP so the press doesn't leak into the loaded demo.
        if ok && rl.IsKeyReleased(rl.KeyboardKey(int(rl.KeyboardKey.ONE) + i)) {
            _current_demo = engine.scene_load_additive_path(path)
            if _current_demo != nil {
                scene_loaded()
                // Hide the menu scene (incl. its camera) while a demo runs.
                _menu_root_set_active(menu, false)
            }
        }
    }
}

@(private = "file")
_DIGITS := [9]string{"1", "2", "3", "4", "5", "6", "7", "8", "9"}

demo_menu_get :: proc() -> ^engine.DemoMenu {
    w := engine.ctx_world()
    for i in 0..<len(w.demo_menus.slots) {
        slot := &w.demo_menus.slots[i]
        if slot.alive && slot.data.enabled do return &slot.data
    }
    return nil
}

@(private = "file")
_menu_root_set_active :: proc(menu: ^engine.DemoMenu, active: bool) {
    w := engine.ctx_world()
    t := engine.pool_get(&w.transforms, engine.Handle(menu.owner))
    if t != nil do t.is_active = active
}
