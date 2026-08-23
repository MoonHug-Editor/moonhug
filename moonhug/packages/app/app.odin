#+feature dynamic-literals
package app

import "moonhug:engine"
import tween "moonhug:packages/tween"
import gfx "moonhug:engine/gfx"
import input "moonhug:engine/input"
import "moonhug:engine/serialization"
import "core:os"
import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:encoding/json"
import "core:encoding/uuid"
import "moonhug:engine/log"

MENU_SCENE_GUID :: "b794d34b-3067-4b7e-ac2d-5cd46c16c5c1"

// The catalog to boot from (docs/AssetPipeline.md "Asset catalog and
// builds"): --catalog[=path] overrides, default = the editor-maintained
// in-place catalog. The app has no scan mode.
_catalog_path: string

main :: proc() {
    // Machine-tagged log lines: the editor's play pipe parses them back into
    // its console (standalone runs just see the tagged text in the terminal).
    log.stdout_tagged = true

    // Normalize the runtime cwd to moonhug/ (same as the editor): asset paths
    // are moonhug-relative, and builds always run from the repo root so the
    // packages: collection flag is one canonical spelling everywhere.
    cwd, _ := os.get_working_directory(context.temp_allocator)
    if !strings.has_suffix(cwd, "moonhug") {
        moonhug_dir, _ := filepath.join({cwd, "moonhug"}, context.temp_allocator)
        os.set_working_directory(moonhug_dir)
    }

    for arg in os.args[1:] {
        if arg == "--catalog" {
            _catalog_path = engine.ASSET_CATALOG_PATH
        } else if strings.has_prefix(arg, "--catalog=") {
            _catalog_path = arg[len("--catalog="):]
        }
    }

    if !gfx.init("App", 800, 600) {
        log.error("gfx init failed")
        return
    }
    defer gfx.shutdown()

    uc := new(engine.UserContext)
    uc.is_editor = false  // standalone binary (engine.application_is_editor)
    uc.is_playing = true  // for the process lifetime (engine.application_is_playing)
    context.user_ptr = uc

    w := new(engine.World)
    engine.w_init(w)
    engine.ctx_get().world = w

    phase_run(Phase.Init)

    // Scene selection, in order: explicit path via first non-flag program arg
    // (the editor's Play button passes its active scene), then the catalog's
    // exported boot scene, then the menu scene by GUID (the dev fallback so
    // the asset can move freely).
    scene_path: string
    for arg in os.args[1:] {
        if strings.has_prefix(arg, "--") do continue
        if len(arg) > 0 && scene_path == "" do scene_path = arg
    }
    if scene_path == "" {
        if boot := engine.asset_db_boot_scene(); boot != {} {
            scene_path, _ = engine.asset_db_get_path(uuid.Identifier(boot))
        }
    }
    if scene_path == "" {
        if guid, gerr := uuid.read(MENU_SCENE_GUID); gerr == nil {
            scene_path, _ = engine.asset_db_get_path(guid)
        }
    }
    if os.exists(scene_path) {
        engine.scene_load_single_path(scene_path)
        scene_loaded()
    } else {
        log.errorf("scene not found: %s", scene_path)
    }

    for !gfx.quit_requested() {
        gfx.poll_events()
        if !gfx.frame_begin() do continue

        // Fixed-rate sim ticks first (0..k this frame, accumulator-driven —
        // docs/FixedTick.md), then the per-frame view tick.
        steps := engine.fixed_frame_ticks(gfx.delta_time())
        for _ in 0 ..< steps {
            input.fixed_latch()
            __fixed_update(engine.fixed_dt())
            engine.fixed_tick_advance()
        }
        __update(gfx.delta_time())

        // F3 toggles the DebugDraw phase (collider wireframes etc).
        if input.key_pressed(.F3) {
            engine.debug_draw_enabled = !engine.debug_draw_enabled
        }

        // World cameras render first (pass stays open, world view_proj still
        // set — debug draw rides it), then the demo menu overlays in screen
        // space within the same swapchain pass.
        if engine.render_world_cameras() {
            if engine.debug_draw_enabled do phase_run(.DebugDraw)
            ws := gfx.window_size()
            gfx.set_view_proj(gfx.matrix4_ortho_pixels(f32(ws.x), f32(ws.y)))
            demo_menu_draw()
            gfx.pass_end()
        }
        gfx.frame_end()

        free_all(context.temp_allocator)
    }

    phase_run(Phase.Shutdown)
}

Phase_Extra :: enum {
    Test,
}

BULLET_SCENE_GUID :: "7db918ca-bee2-4f8a-92de-dc4bec1b7cb9"

@(phase={key=Phase.Init})
app_init :: proc() {
    log.info("App Init")
    register_app_components()
    register_packages()
    register_type_guids()
    phase_run(.SerializationInit)
    phase_run(.ImportersInit)
    phase_run(.TweenNodesInit)
    // The app ALWAYS runs the catalog pipeline — the editor maintains
    // library/catalog.json (dev runs read it in place), exports carry their
    // own. There is no scan mode: scanning and importing are editor machinery
    // (engine_editor), not linked into this binary.
    if _catalog_path == "" do _catalog_path = engine.ASSET_CATALOG_PATH
    if !engine.asset_db_init_from_catalog(_catalog_path) {
        log.errorf("no catalog at %s — run the editor once (it maintains library/catalog.json) or pass --catalog=<path>", _catalog_path)
    }
    engine.texture_cache_init()
    engine.mesh_cache_init()
    engine.material_cache_init()
    engine.shader_cache_init()
    tween.tween_init()

    log.info("App Init done")
}

setup_player_animations :: proc()
{
    it := engine.pool_iterator(players(engine.ctx_world()))
    for p, _ in engine.pool_next(&it) {
        for &ht, i in p.animations{
        	anim_key := fmt.tprintf("Anim%d", i)
         	tween.tween_register(anim_key, &ht)
        }
        break
    }
}

@(phase={key=Phase.Shutdown})
app_shutdown :: proc() {
    log.info("App Shutdown")
}

@(update={order=1})
tween_tick :: proc(dt: f32) {
    tween.tween_tick_running(dt, {})
}

