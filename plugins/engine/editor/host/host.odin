package engine_host

// The engine's side of viewport.Host_Lifecycle: the user context, the world,
// the asset caches and the scene manager, booted and torn down by the editor's
// main. Installed from @(init), linked through scene_views.

import "base:runtime"
import "moonhug:editor/viewport"
import "moonhug:packages/engine"

@(private = "file") _uc: ^engine.UserContext
@(private = "file") _world: ^engine.World

@(init, private = "file")
_install_host_lifecycle :: proc "contextless" () {
	context = runtime.default_context()
	viewport.set_host_lifecycle({
		boot     = _boot,
		init     = _init,
		shutdown = _shutdown,
		release  = _release,
	})
}

@(private = "file")
_boot :: proc() -> rawptr {
	_uc = new(engine.UserContext)
	context.user_ptr = _uc
	_uc.is_editor = true // engine.application_is_editor, never changes at runtime

	_world = new(engine.World)
	engine.w_init(_world)
	engine.ctx_get().world = _world
	return _uc
}

@(private = "file")
_init :: proc() {
	engine.texture_cache_init()
	engine.mesh_cache_init()
	engine.material_cache_init()
	engine.shader_cache_init()
}

@(private = "file")
_shutdown :: proc() {
	engine.texture_cache_shutdown()
	engine.mesh_cache_shutdown()
	engine.material_cache_shutdown()
	engine.shader_cache_shutdown()
	engine.sm_shutdown()
	engine.scene_lib_shutdown()
}

@(private = "file")
_release :: proc() {
	if _world != nil {
		engine.world_destroy_all(_world)
		free(_world)
		_world = nil
	}
	free(_uc)
	_uc = nil
}
