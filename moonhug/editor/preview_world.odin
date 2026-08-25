package editor

// The preview World. Previews and thumbnails instantiate scene content here,
// never in the live world — a scene's components (pool caps, singletons,
// stateful systems) must not collide with a preview copy of themselves.
// Swapping the context's world routes every ctx_world() consumer — spawn,
// bounds, layer walks, render collectors — at the preview content for the
// duration of the bracket:
//
//	prev := preview_world_begin()
//	defer preview_world_end(prev)
//	spawned := engine.scene_instantiate_guid(guid, preview_world_root())
//	defer engine.transform_destroy(spawned)
//	... render ...
//
// The world and its scratch scene are created on first use and live for the
// editor's lifetime; content is spawned and destroyed per render.

import "moonhug:engine"

@(private = "file") _pvw_world: ^engine.World
@(private = "file") _pvw_scene: ^engine.Scene

// Swaps the preview world in. Returns the previous world for preview_world_end.
preview_world_begin :: proc() -> ^engine.World {
	uc := engine.ctx_get()
	prev := uc.world
	if _pvw_world == nil {
		_pvw_world = new(engine.World)
		engine.w_init(_pvw_world)
	}
	uc.world = _pvw_world
	if _pvw_scene == nil {
		_pvw_scene = engine.scene_new()
		engine.scene_ensure_root(_pvw_scene)
	}
	return prev
}

preview_world_end :: proc(prev: ^engine.World) {
	engine.ctx_get().world = prev
}

// Only valid inside a begin/end bracket.
preview_world_root :: proc() -> engine.Transform_Handle {
	return engine.Transform_Handle(_pvw_scene.root.handle)
}

preview_world_shutdown :: proc() {
	if _pvw_scene != nil {
		// The scene's transforms live in the preview world's pools.
		prev := preview_world_begin()
		engine.scene_destroy(_pvw_scene)
		preview_world_end(prev)
		_pvw_scene = nil
	}
	if _pvw_world != nil {
		engine.world_destroy_all(_pvw_world)
		free(_pvw_world)
		_pvw_world = nil
	}
}
