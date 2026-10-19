package engine

// The physics contact hooks: game logic on a component when a contact or a
// trigger overlap of its object begins or ends. A physics plugin collects its
// library's begin and end events after the solver step and dispatches them
// here in the same fixed tick, so a hook may destroy, spawn or push bodies
// freely. There is no stay hook: a component that needs one keeps its own
// set from enter and exit.
//
// A hook runs on the components of the shape's own object only, not on its
// parents or children. Transform.physics_hooked skips objects without a
// hooked component: a component with a hook sets it at awake, and a dispatch
// that finds no hook on the object clears it. All of it runs only while the
// game runs (game_running).

// `proc(c: ^T, other: Transform_Handle)`: the component, and the object whose
// shape it touched.
Physics_Hook_Proc :: proc(c: rawptr, other: Transform_Handle)

// Runs a proc on a component when a collider of its object starts touching
// another collider. `component = T` names a @(component) type of the same
// package, and the proc is `proc(c: ^T, other: Transform_Handle)`, named
// `comp_on_collision_enter_<T>`. A type has at most one.
@(extension_point={attribute="comp_on_collision_enter", target="proc", fields="component"})
component_on_collision_enter_procs: [TypeKey]Physics_Hook_Proc

// Runs a proc on a component when a collider of its object stops touching
// another collider: `comp_on_collision_exit_<T>`, as comp_on_collision_enter.
@(extension_point={attribute="comp_on_collision_exit", target="proc", fields="component"})
component_on_collision_exit_procs: [TypeKey]Physics_Hook_Proc

// Runs a proc on a component when a trigger of its object starts overlapping
// another collider, or a collider of its object enters a trigger:
// `comp_on_trigger_enter_<T>`, as comp_on_collision_enter.
@(extension_point={attribute="comp_on_trigger_enter", target="proc", fields="component"})
component_on_trigger_enter_procs: [TypeKey]Physics_Hook_Proc

// Runs a proc on a component when a trigger overlap of its object ends:
// `comp_on_trigger_exit_<T>`, as comp_on_collision_enter.
@(extension_point={attribute="comp_on_trigger_exit", target="proc", fields="component"})
component_on_trigger_exit_procs: [TypeKey]Physics_Hook_Proc

// Whether a type has any physics contact hook: what sets Transform.physics_hooked.
component_physics_hooked: [TypeKey]bool

Physics_Contact :: enum {
	Collision_Enter,
	Collision_Exit,
	Trigger_Enter,
	Trigger_Exit,
}

_physics_hooks_register :: proc(desc: Component_Desc) {
	k := desc.type_key
	if desc.on_collision_enter != nil do component_on_collision_enter_procs[k] = desc.on_collision_enter
	if desc.on_collision_exit != nil do component_on_collision_exit_procs[k] = desc.on_collision_exit
	if desc.on_trigger_enter != nil do component_on_trigger_enter_procs[k] = desc.on_trigger_enter
	if desc.on_trigger_exit != nil do component_on_trigger_exit_procs[k] = desc.on_trigger_exit
	component_physics_hooked[k] = desc.on_collision_enter != nil || desc.on_collision_exit != nil || desc.on_trigger_enter != nil || desc.on_trigger_exit != nil
}

// Runs the hooks of one contact event on both objects: a's components with
// `other = b`, then b's with `other = a`. A physics plugin calls it for every
// begin and end event its step produced.
physics_contact_dispatch :: proc(kind: Physics_Contact, a, b: Transform_Handle) {
	if !game_running() do return
	w := ctx_world()
	_physics_contact_one(w, kind, a, b)
	_physics_contact_one(w, kind, b, a)
}

@(private = "file")
_physics_contact_one :: proc(w: ^World, kind: Physics_Contact, self, other: Transform_Handle) {
	t := pool_get(&w.transforms, Handle(self))
	if t == nil || !t.physics_hooked do return
	table: ^[TypeKey]Physics_Hook_Proc
	switch kind {
	case .Collision_Enter: table = &component_on_collision_enter_procs
	case .Collision_Exit:  table = &component_on_collision_exit_procs
	case .Trigger_Enter:   table = &component_on_trigger_enter_procs
	case .Trigger_Exit:    table = &component_on_trigger_exit_procs
	}
	// A copy: a hook may add or remove components of its own object.
	comps := make([]Owned, len(t.components), context.temp_allocator)
	copy(comps, t.components[:])
	hooked := false
	for c in comps {
		if !_type_key_valid(c.handle.type_key) do continue
		if !component_physics_hooked[c.handle.type_key] do continue
		hooked = true
		fn := table[c.handle.type_key]
		if fn == nil do continue
		if ptr := world_pool_get(w, c.handle); ptr != nil do fn(ptr, other)
	}
	// No hooked component is left on the object: the next contact skips it.
	if !hooked {
		if t = pool_get(&w.transforms, Handle(self)); t != nil do t.physics_hooked = false
	}
}
