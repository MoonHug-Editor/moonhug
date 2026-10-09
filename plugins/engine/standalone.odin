package engine

// The standalone player: what a game binary does around its phases and its
// ticks. update_gen writes the sequence as __standalone_run in the game's
// update_generated.odin, so a game's main is one call, and these procs are
// the steps it strings together with the game's phase_run and __ticks:
//
//   standalone_prepare()
//   if !standalone_window_open() do return
//   defer standalone_window_close()
//   phase_run(.EngineInit)        // world, catalog, caches
//   context.user_ptr = core.user_context  // before the defer: a deferred
//   defer phase_run(.EngineShutdown)      // call keeps its defer's context
//   phase_run(.Init)              // registration first, then the game
//   defer phase_run(.Shutdown)
//   if standalone_load_boot_scene() do phase_run(.SceneLoaded)
//   for standalone_frame_begin() {
//       frame_tick(__ticks, standalone_frame_dt())
//       if standalone_render_begin() {
//           if debug_draw_enabled do phase_run(.DebugDraw)
//           standalone_render_end()
//       }
//       standalone_frame_end()
//   }
//
// The window, its title and size, and the fallback boot scene come from the
// Player project setting.

import "core:encoding/uuid"
import "core:os"
import "core:strings"
import gfx "moonhug:host/gfx"
import "moonhug:host/gizmos"
import "moonhug:host/input"
import "moonhug:host/log"

// The catalog to boot from (docs/core/AssetPipeline.md "Asset catalog and
// builds"): --catalog[=path] overrides, the export's own beside the binary
// next, the editor-maintained in-place catalog last. The player has no scan
// mode.
@(private = "file") _catalog_path: string
// The scene the first non-flag program argument names: the editor's Play
// passes its active scene.
@(private = "file") _scene_arg: string

// Before the window: the log, the cwd and the program arguments.
standalone_prepare :: proc() {
	// Machine-tagged log lines: the editor's play pipe parses them back into
	// its console (standalone runs just see the tagged text in the terminal).
	log.stdout_tagged = true
	// Normalize the runtime cwd to moonhug/ (same as the editor): asset paths
	// are moonhug-relative, and builds always run from the repo root so the
	// packages: collection flag is one canonical spelling everywhere.
	project_chdir_root()

	for arg in os.args[1:] {
		switch {
		case arg == "--catalog":
			_catalog_path = ASSET_CATALOG_PATH
		case strings.has_prefix(arg, "--catalog="):
			_catalog_path = arg[len("--catalog="):]
		case strings.has_prefix(arg, "--"):
		case _scene_arg == "" && len(arg) > 0:
			_scene_arg = arg
		}
	}
	// Launched bare, the binary finds its own export: <exe>_data/catalog.json
	// beside it, the Game + Game_Data layout run configs stage. So a build
	// double-clicked in builds/ boots its stamped scene instead of falling
	// through to the editor's in-place catalog and the dev menu.
	if _catalog_path == "" {
		if exe, eerr := os.get_executable_path(context.temp_allocator); eerr == nil {
			beside := strings.concatenate({exe, "_data/catalog.json"}, context.temp_allocator)
			if os.exists(beside) do _catalog_path = beside
		}
	}
	if _catalog_path == "" do _catalog_path = ASSET_CATALOG_PATH
}

// The window from the Player setting. False when the platform refuses, the
// only fatal step of a boot.
standalone_window_open :: proc() -> bool {
	_ensure_player_settings()
	title := strings.clone_to_cstring(player_settings.title, context.temp_allocator)
	if !gfx.init(title, player_settings.width, player_settings.height) {
		log.error("gfx init failed")
		return false
	}
	return true
}

standalone_window_close :: proc() {
	gfx.shutdown()
}

// The asset database from the catalog, after the world and before the
// caches.
@(phase={key=EngineInit, order=5, mode=App})
standalone_catalog_init :: proc() {
	if !asset_db_init_from_catalog(_catalog_path) {
		log.errorf("no catalog at %s — run the editor once (it maintains library/catalog.json) or pass --catalog=<path>", _catalog_path)
	}
}

// Loads the boot scene: the program argument, else the catalog's exported
// boot scene, else the Player setting's fallback. False, with the reason
// logged, when none names a file.
standalone_load_boot_scene :: proc() -> bool {
	path := _scene_arg
	if path == "" {
		if boot := asset_db_boot_scene(); boot != {} {
			path, _ = asset_db_get_path(uuid.Identifier(boot))
		}
	}
	if path == "" && player_settings.boot_scene != "" {
		if guid, gerr := uuid.read(player_settings.boot_scene); gerr == nil {
			path, _ = asset_db_get_path(guid)
		} else {
			log.errorf("Player setting boot_scene %q is not a guid", player_settings.boot_scene)
		}
	}
	if !os.exists(path) {
		log.errorf("scene not found: %s", path)
		return false
	}
	log.infof("booting %s", path)
	scene_load_single_path(path)
	input.set_game_scope(true) // the whole frame is the game's; window focus gates it
	return true
}

// Events and the frame. False once the window wants to quit. A frame the
// platform skips (minimized) polls again until one begins.
standalone_frame_begin :: proc() -> bool {
	for {
		if gfx.quit_requested() do return false
		gfx.poll_events()
		if gfx.frame_begin() do break
	}
	// Gameplay gizmos measure against the camera they show in: the one
	// render_world_cameras draws last, at the window size (docs/core/Gizmos.md).
	if cam := camera_active(); cam != nil {
		ws := gfx.window_size()
		gizmos.set_view(camera_render_view(cam, f32(ws.x), f32(ws.y)))
	}
	// F3 toggles the DebugDraw phase (collider wireframes etc).
	if input.key_pressed(.F3) do debug_draw_enabled = !debug_draw_enabled
	return true
}

standalone_frame_dt :: proc() -> f32 {
	return gfx.delta_time()
}

// World cameras render. The pass stays open with the world view_proj set, so
// the DebugDraw phase rides it, then standalone_render_end closes it.
standalone_render_begin :: proc() -> bool {
	return render_world_cameras()
}

standalone_render_end :: proc() {
	gfx.pass_end()
}

standalone_frame_end :: proc() {
	gfx.frame_end()
	free_all(context.temp_allocator)
}
