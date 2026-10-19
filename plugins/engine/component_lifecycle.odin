package engine

// The game's per-component lifecycle hooks (docs/Components.md "Game
// lifecycle"): @(comp_awake) when an instance enters the running game,
// @(comp_on_destroy) when it leaves it. Both run only while the game runs in
// the game world (game_running): never in edit mode, never in a preview or
// thumbnail world.
//
// - Awake runs once per instance: at play start for every loaded scene, and
//   right after a creation while the game runs (scene load, instantiate,
//   paste, duplicate, add component). Active and enabled state do not matter.
// - Awake order: an object's components in their list order, then its
//   children, depth first.
// - A creation inside another (an instantiate pastes, a build adds
//   components) runs in the outer one's batch, so the outermost creation
//   awakes the whole result once, after every component exists.
// - comp_on_destroy runs when an instance leaves the running game: its object
//   destroyed, the component removed, its scene unloaded, play stopped, the
//   player quitting. cleanup_T runs after it, in every mode.

// Runs a proc once when an instance of one component type enters the running
// game: at play start, or right after its creation while the game runs.
//
// `component = T` names a @(component) type of the same package, and the proc
// is `proc(c: ^T)`, named `comp_awake_<T>`. Every component of the new objects
// exists when it runs, with its references bound. A type has at most one: the
// name is fixed and it sits in the type's package.
@(extension_point={attribute="comp_awake", target="proc", fields="component"})
component_awake_procs: [TypeKey]proc(rawptr)

// Runs a proc when an instance of one component type leaves the running game:
// its object destroyed, the component removed, its scene unloaded, play
// stopped or the player quitting. Never in edit mode.
//
// `component = T` names a @(component) type of the same package, and the proc
// is `proc(c: ^T)`, named `comp_on_destroy_<T>`. It is for game logic and for
// what comp_awake_<T> created outside the instance. cleanup_T runs right after
// it and frees what the instance owns. A type has at most one: the name is
// fixed and it sits in the type's package.
@(extension_point={attribute="comp_on_destroy", target="proc", fields="component"})
component_on_destroy_procs: [TypeKey]proc(rawptr)

// Whether the game runs in the current world: playing, and the context's
// world is the game world, not a preview or thumbnail world swapped in.
game_running :: proc() -> bool {
	uc := ctx_get()
	return uc != nil && uc.is_playing && uc.world != nil && uc.world == uc.game_world
}

// Open creation batches on this thread: a creation inside one skips its own
// awake, the outermost awakes the result.
@(private = "file", thread_local)
_awake_batch: int

// Opens a creation that awakes its result at the end. Creations inside it skip
// their own awake. Pair every call with awake_batch_end.
awake_batch_begin :: proc() {
	_awake_batch += 1
}

// Closes the batch awake_batch_begin opened. The outermost one awakes the
// subtree under `root`. A zero handle awakes nothing.
awake_batch_end :: proc(root: Transform_Handle) {
	assert(_awake_batch > 0, "awake_batch_end without awake_batch_begin")
	_awake_batch -= 1
	awake_subtree(root)
}

// Runs the @(comp_awake) procs under `root` while the game runs and no batch
// is open: each object's components in list order, then its children, depth
// first. What an awake proc creates awakes on its own, so the walk visits only
// the components and children each object had when the walk reached it.
awake_subtree :: proc(root: Transform_Handle) {
	if _awake_batch > 0 || !game_running() do return
	_awake_walk(ctx_world(), root)
}

// The @(comp_awake) proc of one component, while the game runs and no batch is
// open: the awake of a component added on its own.
component_awake :: proc(key: TypeKey, ptr: rawptr) {
	if _awake_batch > 0 || !game_running() do return
	if !_type_key_valid(key) do return
	if fn := component_awake_procs[key]; fn != nil do fn(ptr)
}

@(private = "file")
_awake_walk :: proc(w: ^World, tH: Transform_Handle) {
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil do return
	// Copies: an awake proc may add components or children, which awake on
	// their own, or destroy them, which the handle checks below skip.
	comps := make([]Owned, len(t.components), context.temp_allocator)
	copy(comps, t.components[:])
	children := make([]Ref, len(t.children), context.temp_allocator)
	copy(children, t.children[:])
	for c in comps {
		if !_type_key_valid(c.handle.type_key) do continue
		fn := component_awake_procs[c.handle.type_key]
		if fn == nil do continue
		if ptr := world_pool_get(w, c.handle); ptr != nil do fn(ptr)
	}
	for c in children do _awake_walk(w, Transform_Handle(c.handle))
}

// A component instance leaves the world: its @(comp_on_destroy) proc while the
// game runs, then its cleanup_T frees what it owns, in every mode. Runs on
// destroy and on removal, before the pool slot goes.
component_on_destroy :: proc(key: TypeKey, ptr: rawptr) {
	_component_on_destroy_notify(key, ptr)
	type_cleanup(key, ptr)
}

@(private = "file")
_component_on_destroy_notify :: proc(key: TypeKey, ptr: rawptr) {
	if !game_running() do return
	if fn := component_on_destroy_procs[key]; fn != nil do fn(ptr)
}

// Starts or stops the game in the game world: Application.isPlaying. The
// player starts it once at EngineInit, the editor's Simulate at Start and
// Stop.
//
// - Starting awakes every loaded scene, in scene slot order.
// - Stopping runs comp_on_destroy on every live component first, while the
//   game still runs, and drops the pending destroys. What is destroyed after
//   it (a Simulate restore, the world teardown) only runs cleanup_T.
application_set_playing :: proc(playing: bool) {
	uc := ctx_get()
	if uc == nil || uc.is_playing == playing do return
	if playing {
		uc.is_playing = true
		_awake_loaded_scenes()
		return
	}
	_on_destroy_all()
	if game_running() do _destroy_queue_drop(ctx_world())
	uc.is_playing = false
}

// The scenes are taken by session id first: an awake proc may load or unload
// scenes, and a scene it loads awakes on its own.
@(private = "file")
_awake_loaded_scenes :: proc() {
	sm := ctx_scene_manager()
	ids := make([dynamic]u32, 0, sm.count, context.temp_allocator)
	for i in 0 ..< sm.count {
		if s := sm.loaded[i]; s != nil do append(&ids, s.session_id)
	}
	for id in ids {
		if s := sm_scene_find_by_session_id(id); s != nil do awake_subtree(Transform_Handle(s.root.handle))
	}
}

// comp_on_destroy on every live component of the game world, type by type.
// Only the types that have the proc are visited.
@(private = "file")
_on_destroy_all :: proc() {
	if !game_running() do return
	w := ctx_world()
	for fn, key in component_on_destroy_procs {
		if fn == nil do continue
		desc := component_registry[key]
		pool := w.ext_pools[key]
		if pool == nil || desc.each_alive == nil do continue
		desc.each_alive(pool, _component_on_destroy_notify)
	}
}
