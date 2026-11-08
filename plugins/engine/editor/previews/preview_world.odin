package previews

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
// editor's lifetime. Content is spawned and destroyed per render, except the
// one instance a live preview keeps between frames (preview_world_hold).

import "moonhug:packages/engine"

@(private = "file") _pvw_world: ^engine.World
@(private = "file") _pvw_scene: ^engine.Scene
@(private = "file") _pvw_prev_active: ^engine.Scene
// Frees the one instance a live preview keeps in the world between frames,
// nil when none is kept.
@(private = "file") _pvw_held: proc()

// Swaps the preview world in. Returns the previous world for preview_world_end.
//
// The ACTIVE SCENE is blinded for the bracket: the scene manager is global,
// not per-world, so anything inside that consults sm_scene_get_active() —
// transform_new stamping t.scene and minting lids into the scene's bimap —
// would reach the LIVE scene from preview code and cross-link the worlds.
// Preview code addresses its scene explicitly, so nothing here needs it.
preview_world_begin :: proc() -> ^engine.World {
	uc := engine.ctx_get()
	prev := uc.world
	if _pvw_world == nil {
		_pvw_world = new(engine.World)
		engine.w_init(_pvw_world)
	}
	uc.world = _pvw_world
	_pvw_prev_active = engine.sm_scene_get_active()
	engine.sm_scene_set_active(nil)
	if _pvw_scene == nil {
		_pvw_scene = engine.scene_new()
		engine.scene_ensure_root(_pvw_scene)
	}
	return prev
}

preview_world_end :: proc(prev: ^engine.World) {
	engine.sm_scene_set_active(_pvw_prev_active)
	_pvw_prev_active = nil
	engine.ctx_get().world = prev
}

// Takes the world's one kept instance, for a live preview that keeps its
// content between frames: a scene preview's instance, a clip preview's rig.
// Every render draws the whole world, so the instance another preview kept
// would draw into this one's picture: it is released first. `release` frees
// the caller's instance and forgets it, so that preview spawns again the next
// time it shows. Inside a begin/end bracket.
preview_world_hold :: proc(release: proc()) {
	if _pvw_held != nil && _pvw_held != release do _pvw_held()
	_pvw_held = release
}

// Releases the kept instance before other content renders in the world (a
// thumbnail), which would otherwise draw it too. Inside a begin/end bracket.
preview_world_release_held :: proc() {
	held := _pvw_held
	_pvw_held = nil
	if held != nil do held()
}

// Only valid inside a begin/end bracket.
preview_world_root :: proc() -> engine.Transform_Handle {
	return engine.Transform_Handle(_pvw_scene.root.handle)
}

preview_world_shutdown :: proc() {
	if _pvw_scene != nil {
		// The scene's transforms live in the preview world's pools.
		prev := preview_world_begin()
		preview_world_release_held()
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
