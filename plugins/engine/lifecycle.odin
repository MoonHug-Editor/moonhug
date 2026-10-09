package engine

// The engine's startup and teardown as phase subscribers, one set for every
// binary: the editor runs EngineInit before EditorInit and EngineShutdown
// after EditorShutdown, the player runs them from the generated
// __standalone_run. `mode` picks the pieces one binary needs. Shutdown
// phases run in descending order, so a pair shares its `order`.

import core "moonhug:host/core"

@(private = "file") _uc: ^UserContext
@(private = "file") _world: ^World

// The user context and the world, before anything touches a world.
@(phase={key=EngineInit, order=0})
engine_init_world :: proc() {
	_uc = new(UserContext)
	core.user_context = _uc
	context.user_ptr = _uc
	_world = new(World)
	w_init(_world)
	ctx_get().world = _world
}

// Unity's Application.isEditor: fixed per binary.
@(phase={key=EngineInit, order=1, mode=Editor})
engine_init_editor_flags :: proc() {
	_uc.is_editor = true
}

// The player plays for the process lifetime.
@(phase={key=EngineInit, order=1, mode=App})
engine_init_player_flags :: proc() {
	_uc.is_playing = true
}

@(phase={key=EngineInit, order=10})
engine_init_caches :: proc() {
	texture_cache_init()
	mesh_cache_init()
	material_cache_init()
	shader_cache_init()
}

@(phase={key=EngineShutdown, order=10})
engine_shutdown_caches :: proc() {
	texture_cache_shutdown()
	mesh_cache_shutdown()
	material_cache_shutdown()
	shader_cache_shutdown()
	sm_shutdown()
	scene_lib_shutdown()
}

@(phase={key=EngineShutdown, order=0})
engine_shutdown_world :: proc() {
	if _world != nil {
		world_destroy_all(_world)
		free(_world)
		_world = nil
	}
	free(_uc)
	_uc = nil
	core.user_context = nil
}
