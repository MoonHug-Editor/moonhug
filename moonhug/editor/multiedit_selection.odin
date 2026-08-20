package editor

// Turning a scene selection into what the inspector draws.
//
// The inspector draws the ACTIVE object and treats the rest of the selection as
// peers (see inspector/multiedit.odin). This file answers the two questions
// that takes: which components the whole selection has in common, and where the
// matching instance lives on each of the other objects.

import engine "../engine"
import "inspector"

// A component the whole selection shares: the active object's instance, plus
// the matching instance on every other selected object.
Multi_Component :: struct {
	comp_index: int, // index into the ACTIVE transform's components
	peers:      []inspector.Multi_Peer,
}

// Components present on every selected transform.
//
// Matching is by (TypeKey, nth instance of that key). Component lists are lists,
// not sets — an object can carry two SpriteRenderers — so the type alone does
// not name an instance. Pairing them by ordinal is Unity's rule and keeps a
// stable answer as the selection changes.
//
// The result follows the ACTIVE object's component order, so the inspector does
// not reshuffle rows when the selection grows.
//
// Fields never need comparing: a component's layout comes from its Odin struct
// type, so equal TypeKey means identical fields by construction. That is the
// whole property-list intersection, and it is why this is a set operation rather
// than a descriptor comparison.
multi_common_components :: proc(
	active_tH: engine.Transform_Handle,
	sel: []engine.Transform_Handle,
	allocator := context.temp_allocator,
) -> []Multi_Component {
	w := engine.ctx_world()
	if w == nil do return nil
	active := engine.pool_get(&w.transforms, engine.Handle(active_tH))
	if active == nil do return nil

	// Peers only — the active object is what gets drawn, not a peer of itself.
	others := make([dynamic]engine.Transform_Handle, 0, len(sel), context.temp_allocator)
	for h in sel {
		if h == active_tH do continue
		if engine.pool_get(&w.transforms, engine.Handle(h)) == nil do continue
		append(&others, h)
	}
	if len(others) == 0 do return nil

	out := make([dynamic]Multi_Component, 0, len(active.components), allocator)

	// How many of this TypeKey have been seen so far on the active object: the
	// ordinal that identifies which instance to pair with.
	seen: map[engine.TypeKey]int
	defer delete(seen)

	for comp, comp_index in active.components {
		key := comp.handle.type_key
		if key == engine.INVALID_TYPE_KEY do continue
		if engine.world_pool_get(w, comp.handle) == nil do continue

		ordinal := seen[key]
		seen[key] = ordinal + 1

		peers := make([dynamic]inspector.Multi_Peer, 0, len(others), allocator)
		complete := true
		for other_tH in others {
			base, handle, ok := _nth_component_of_key(other_tH, key, ordinal)
			if !ok {
				complete = false
				break
			}
			ot := engine.pool_get(&w.transforms, engine.Handle(other_tH))
			// A component's override targets the COMPONENT's local id, not the
			// transform's — that is what the single-object path records.
			p_host, _ := _nested_identity(other_tH)
			comp_lid := engine.Local_ID(0)
			if base != nil do comp_lid = (cast(^engine.CompData)base).local_id
			append(&peers, inspector.Multi_Peer{
				base = base,
				handle = handle,
				scene = ot.scene if ot != nil else nil,
				nested_host = p_host,
				nested_lid = comp_lid,
			})
		}

		// Missing on even one selected object means the row is not common, and a
		// partial peer list would silently edit a subset of the selection.
		if !complete {
			delete(peers)
			continue
		}
		append(&out, Multi_Component{comp_index = comp_index, peers = peers[:]})
	}

	return out[:]
}

// The `ordinal`-th component of type `key` on `tH`.
@(private = "file")
_nth_component_of_key :: proc(
	tH: engine.Transform_Handle,
	key: engine.TypeKey,
	ordinal: int,
) -> (base: rawptr, handle: engine.Handle, ok: bool) {
	w := engine.ctx_world()
	if w == nil do return nil, {}, false
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return nil, {}, false

	n := 0
	for comp in t.components {
		if comp.handle.type_key != key do continue
		if n == ordinal {
			ptr := engine.world_pool_get(w, comp.handle)
			if ptr == nil do return nil, {}, false
			return ptr, comp.handle, true
		}
		n += 1
	}
	return nil, {}, false
}

// Peers for the TRANSFORM itself, so position/rotation/scale multi-edit the same
// way component fields do.
multi_transform_peers :: proc(
	active_tH: engine.Transform_Handle,
	sel: []engine.Transform_Handle,
	allocator := context.temp_allocator,
) -> []inspector.Multi_Peer {
	w := engine.ctx_world()
	if w == nil do return nil

	peers := make([dynamic]inspector.Multi_Peer, 0, len(sel), allocator)
	for h in sel {
		if h == active_tH do continue
		t := engine.pool_get(&w.transforms, engine.Handle(h))
		if t == nil do continue
		p_host, p_lid := _nested_identity(h)
		append(&peers, inspector.Multi_Peer{
			base = rawptr(t),
			handle = engine.Handle(h),
			scene = t.scene,
			nested_host = p_host,
			nested_lid = p_lid,
		})
	}
	return peers[:]
}

// Whether a selection can be multi-edited at all.
//
// Prefab-instance content is INCLUDED, the same as Unity: an edit to instance
// content records an override against its own instance, and each peer carries
// the host/local_id pair that identifies which one (see Multi_Peer). Excluding
// it made multiedit switch itself off for most real selections, since a scene of
// any size is mostly prefab instances.
multi_selection_editable :: proc(sel: []engine.Transform_Handle) -> bool {
	if len(sel) < 2 do return false
	w := engine.ctx_world()
	if w == nil do return false
	for h in sel {
		if engine.pool_get(&w.transforms, engine.Handle(h)) == nil do return false
	}
	return true
}

// The prefab-instance identity of an object, or zeros when it is plain scene
// content. `lid` is what an override record targets; `host` names the instance
// the record lives on.
@(private = "file")
_nested_identity :: proc(tH: engine.Transform_Handle) -> (host: engine.Transform_Handle, lid: engine.Local_ID) {
	w := engine.ctx_world()
	if w == nil do return {}, 0
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return {}, 0

	is_host := engine.scene_find_nested_scene_for_host(t.scene, tH) != nil
	if !t.nested_owned && !is_host do return {}, 0

	// Same rule the single-object path uses: the immediate host holds the records
	// about this transform's prefab-level content, and a host that is itself
	// nested-owned still resolves through its own immediate host.
	host = tH if is_host else engine.transform_immediate_nested_host(tH)
	if host == {} do return {}, 0

	// A transform that IS the instance root targets the prefab's source root id;
	// descendants' live local_id already matches the inner-prefab namespace.
	lid = t.local_id
	if tH == host {
		ht := engine.pool_get(&w.transforms, engine.Handle(host))
		if ht != nil {
			if ns := engine.scene_find_nested_scene_for_host(ht.scene, host); ns != nil && ns.source_root_id != 0 {
				lid = ns.source_root_id
			}
		}
	}
	return host, lid
}
