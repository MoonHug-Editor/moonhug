package engine

// The game's per-component lifecycle hooks (docs/Components.md "Game
// lifecycle"): @(comp_awake) when an instance enters the running game,
// @(comp_on_enable) / @(comp_on_disable) when its effective enabled state
// changes, @(comp_on_destroy) when it leaves the game. All run only while the
// game runs in the game world (game_running): never in edit mode, never in a
// preview or thumbnail world.
//
// - Awake runs once per instance: at play start for every loaded scene, and
//   right after a creation while the game runs (scene load, instantiate,
//   paste, duplicate, add component). Active and enabled state do not matter.
// - Awake order: an object's components in their list order, then its
//   children, depth first. A creation runs in two passes: awake on everything,
//   then on_enable on everything enabled, so every on_enable sees the whole
//   creation awake.
// - A creation inside another (an instantiate pastes, a build adds
//   components) runs in the outer one's batch, so the outermost creation
//   awakes the whole result once, after every component exists.
// - Enabled means `enabled && transform_active_in_hierarchy(owner)`.
//   CompData.notified_enabled records what the hooks last reported, and
//   enabled_sync fires on_enable or on_disable when the state differs. Game
//   code changes the flags through transform_set_active and comp_set_enabled,
//   which sync at once. Every editor write (inspector, undo, MCP, overrides)
//   reaches enabled_sync through the undo stack's value_written hook or the
//   nested-scene patch procs. enabled_verify, run by frame_tick in debug
//   builds and by the tests, panics on a component the hooks missed.
// - comp_on_destroy runs when an instance leaves the running game: its object
//   destroyed, the component removed, its scene unloaded, play stopped, the
//   player quitting. on_disable runs before it when the instance was enabled.
//   cleanup_T runs after it, in every mode.

import "core:fmt"

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

// Runs a proc when an instance of one component type becomes enabled in the
// running game: right after its awake when it is enabled, and on every change
// to enabled while its object is active in the hierarchy, or to that.
//
// `component = T` names a @(component) type of the same package, and the proc
// is `proc(c: ^T)`, named `comp_on_enable_<T>`. The first call sees every
// component of the same creation awake. A type has at most one.
@(extension_point={attribute="comp_on_enable", target="proc", fields="component"})
component_on_enable_procs: [TypeKey]proc(rawptr)

// Runs a proc when an instance of one component type stops being enabled in
// the running game: its enabled flag or its object's active state goes off,
// or it leaves the game while enabled (before comp_on_destroy).
//
// `component = T` names a @(component) type of the same package, and the proc
// is `proc(c: ^T)`, named `comp_on_disable_<T>`. A type has at most one.
@(extension_point={attribute="comp_on_disable", target="proc", fields="component"})
component_on_disable_procs: [TypeKey]proc(rawptr)

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

// Runs the game hooks of a creation under `root` while the game runs and no
// batch is open: @(comp_awake) on every component, each object's components
// in list order then its children, depth first, then on_enable on every
// enabled one in the same order. What an awake proc creates awakes on its
// own, so the walk visits only the components and children each object had
// when the walk reached it.
awake_subtree :: proc(root: Transform_Handle) {
	if _awake_batch > 0 || !game_running() do return
	w := ctx_world()
	_walk(w, root, _awake_one)
	_walk(w, root, enabled_sync)
}

// The game hooks of one component added on its own, while the game runs and
// no batch is open: its @(comp_awake), then on_enable when it is enabled.
component_awake :: proc(key: TypeKey, ptr: rawptr) {
	if _awake_batch > 0 || !game_running() do return
	if !_type_key_valid(key) do return
	_awake_one(key, ptr)
	enabled_sync(key, ptr)
}

@(private = "file")
_awake_one :: proc(key: TypeKey, ptr: rawptr) {
	if component_physics_hooked[key] {
		if t := pool_get(&ctx_world().transforms, Handle((cast(^CompData)ptr).owner)); t != nil do t.physics_hooked = true
	}
	if fn := component_awake_procs[key]; fn != nil do fn(ptr)
}

// Calls `fn` on every live component under `tH`: an object's components in
// list order, then its children, depth first.
@(private = "file")
_walk :: proc(w: ^World, tH: Transform_Handle, fn: proc(key: TypeKey, ptr: rawptr)) {
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil do return
	// Copies: a hook may add components or children, which get their hooks
	// on their own, or destroy them, which the handle checks below skip.
	comps := make([]Owned, len(t.components), context.temp_allocator)
	copy(comps, t.components[:])
	children := make([]Ref, len(t.children), context.temp_allocator)
	copy(children, t.children[:])
	for c in comps {
		if !_type_key_valid(c.handle.type_key) do continue
		if ptr := world_pool_get(w, c.handle); ptr != nil do fn(c.handle.type_key, ptr)
	}
	for c in children do _walk(w, Transform_Handle(c.handle), fn)
}

// Whether a component counts as enabled for the game: its flag, and its object
// active with every ancestor.
component_enabled :: proc(ptr: rawptr) -> bool {
	base := cast(^CompData)ptr
	return base.enabled && transform_active_in_hierarchy(base.owner)
}

// Brings one component's reported state up to date: on_enable or on_disable
// fires when component_enabled differs from what was last reported. A no-op
// outside the running game.
enabled_sync :: proc(key: TypeKey, ptr: rawptr) {
	if !game_running() do return
	base := cast(^CompData)ptr
	now := component_enabled(ptr)
	if now == base.notified_enabled do return
	base.notified_enabled = now
	if now {
		if fn := component_on_enable_procs[key]; fn != nil do fn(ptr)
	} else {
		if fn := component_on_disable_procs[key]; fn != nil do fn(ptr)
	}
}

// enabled_sync on every component under an object: for a change of the
// object's active state.
enabled_sync_subtree :: proc(tH: Transform_Handle) {
	if !game_running() do return
	_walk(ctx_world(), tH, enabled_sync)
}

// enabled_sync for the owner of a pooled handle: an object's subtree, or one
// component. The undo stack calls it after every value write (the inspector,
// undo and redo, an MCP write, a multi-edit).
enabled_sync_handle :: proc(h: Handle) {
	if !game_running() || !_type_key_valid(h.type_key) do return
	if h.type_key == .Transform {
		enabled_sync_subtree(Transform_Handle(h))
		return
	}
	if ptr := world_pool_get(ctx_world(), h); ptr != nil do enabled_sync(h.type_key, ptr)
}

// Sets an object's active flag and syncs its subtree at once: the setter game
// code uses. An editor write goes through the undo stack instead, which syncs
// after the write.
transform_set_active :: proc(tH: Transform_Handle, active: bool) {
	t := pool_get(&ctx_world().transforms, Handle(tH))
	if t == nil || t.is_active == active do return
	t.is_active = active
	enabled_sync_subtree(tH)
}

// Sets a component's enabled flag and syncs it at once: the setter game code
// uses.
comp_set_enabled :: proc(c: ^CompData, enabled: bool) {
	if c.enabled == enabled do return
	c.enabled = enabled
	h, ok := comp_handle_of(c)
	if !ok do return
	enabled_sync(h.type_key, c)
}

// Panics on a component whose reported enabled state differs from its real
// one: a writer that bypassed the setters and the undo stack. Visits only the
// types that have an enable hook. frame_tick runs it in debug builds, the
// tests run it directly. A no-op outside the running game.
enabled_verify :: proc() {
	if !game_running() do return
	w := ctx_world()
	for key in TypeKey {
		if component_on_enable_procs[key] == nil && component_on_disable_procs[key] == nil do continue
		desc := component_registry[key]
		pool := w.ext_pools[key]
		if pool == nil || desc.each_alive == nil do continue
		desc.each_alive(pool, proc(key: TypeKey, ptr: rawptr) {
			base := cast(^CompData)ptr
			if component_enabled(ptr) == base.notified_enabled do return
			t := pool_get(&ctx_world().transforms, Handle(base.owner))
			name := t != nil ? t.name : "?"
			fmt.panicf("component_lifecycle: %v on %q is %s but was reported %s: a writer changed enabled or is_active without transform_set_active, comp_set_enabled or the undo stack", key, name, component_enabled(ptr) ? "enabled" : "disabled", base.notified_enabled ? "enabled" : "disabled")
		})
	}
}

// A component instance leaves the world: on_disable when it was enabled and
// its @(comp_on_destroy) proc, while the game runs, then its cleanup_T frees
// what it owns, in every mode. Runs on destroy and on removal, before the pool
// slot goes.
component_on_destroy :: proc(key: TypeKey, ptr: rawptr) {
	_component_on_destroy_notify(key, ptr)
	type_cleanup(key, ptr)
}

@(private = "file")
_component_on_destroy_notify :: proc(key: TypeKey, ptr: rawptr) {
	if !game_running() do return
	base := cast(^CompData)ptr
	if base.notified_enabled {
		base.notified_enabled = false
		if fn := component_on_disable_procs[key]; fn != nil do fn(ptr)
	}
	if fn := component_on_destroy_procs[key]; fn != nil do fn(ptr)
}

// Starts or stops the game in the game world: Application.isPlaying. The
// player starts it once at EngineInit, the editor's Simulate at Start and
// Stop.
//
// - Starting awakes every loaded scene, in scene slot order.
// - Stopping runs on_disable and comp_on_destroy on every live component
//   first, while the game still runs, and drops the pending destroys. What is destroyed after
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

// on_disable and comp_on_destroy on every live component of the game world,
// type by type. Only the types that have one of the procs are visited.
@(private = "file")
_on_destroy_all :: proc() {
	if !game_running() do return
	w := ctx_world()
	for key in TypeKey {
		if component_on_destroy_procs[key] == nil && component_on_disable_procs[key] == nil do continue
		desc := component_registry[key]
		pool := w.ext_pools[key]
		if pool == nil || desc.each_alive == nil do continue
		desc.each_alive(pool, _component_on_destroy_notify)
	}
}
