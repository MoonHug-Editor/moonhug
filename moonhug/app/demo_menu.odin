package app

// In-game demo hub: lists the scenes authored on the DemoMenu component and
// loads one additively on its number key (1..9); ESC unloads it back to the
// menu. Draws with gfx.debug_text, so demo_menu_draw must run inside an open
// gfx pass under a pixel-ortho view_proj (called from main after world
// rendering, same swapchain pass).

import "core:path/filepath"
import "core:strings"
import "core:encoding/uuid"
import gfx "../engine/gfx"
import input "../engine/input"
import "../engine"

@(private = "file")
_current_demo: ^engine.Scene

demo_menu_draw :: proc() {
    menu := demo_menu_get()
    if menu == nil do return

    WHITE :: [4]f32{0.96, 0.96, 0.96, 1}

    if _current_demo != nil {
        gfx.debug_text({10, 10}, 20, WHITE, "ESC: back to menu")
        if engine.debug_draw_enabled {
            gfx.debug_text({10, 36}, 20, WHITE, "F3: colliders (on)")
        }
        if input.key_released(.ESCAPE) {
            engine.sm_scene_unload(_current_demo)
            _current_demo = nil
            _menu_root_set_active(menu, true)
        }
        return
    }

    gfx.debug_text({10, 10}, 30, WHITE, "DEMOS")
    y := f32(50)
    for guid, i in menu.demos {
        if i >= 9 do break // number keys only reach 9
        path, ok := engine.asset_db_get_path(uuid.Identifier(guid))
        label := filepath.short_stem(filepath.base(path)) if ok else "(missing scene)"
        line := strings.concatenate({_DIGITS[i], ": ", label}, context.temp_allocator)
        gfx.debug_text({10, y}, 20, WHITE, line)
        y += 26

        // React on key UP so the press doesn't leak into the loaded demo.
        if ok && input.key_released(input.Key(int(input.Key._1) + i)) {
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

demo_menu_get :: proc() -> ^DemoMenu {
    pool := demo_menus(engine.ctx_world())
    if pool == nil do return nil
    for i in 0..<len(pool.slots) {
        slot := &pool.slots[i]
        if slot.alive && slot.data.enabled do return &slot.data
    }
    return nil
}

@(private = "file")
_menu_root_set_active :: proc(menu: ^DemoMenu, active: bool) {
    w := engine.ctx_world()
    t := engine.pool_get(&w.transforms, engine.Handle(menu.owner))
    if t != nil do t.is_active = active
}
