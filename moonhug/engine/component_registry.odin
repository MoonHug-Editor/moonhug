package engine

// Runtime component registry: lets packages OUTSIDE engine (app, plugins)
// define components without engine importing them. A package registers a
// Component_Desc per component (prebuild generates those registrations); the
// engine then stores instances in per-World ext pools and serializes them as
// guid-tagged blob records (Ext_Component_Record) in scene files.
//
// On-disk identity is the component's type GUID — NEVER TypeKey, whose numeric
// value shifts whenever the set of types changes.
//
// Everything json/reflection-shaped is handled generically here via the desc's
// typeid; only pool instantiation and lifecycle thunks are generated per
// component (they need the concrete type at compile time).

import "base:runtime"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import "core:mem"
import "core:strings"
import "log"

Component_Desc :: struct {
	type_key:  TypeKey,
	type_guid: uuid.Identifier,
	tid:       typeid, // component type T
	ptr_tid:   typeid, // ^T — unmarshal needs a pointer-typed any

	// storage thunks (instantiated per World)
	pool_create:  proc() -> rawptr,
	pool_destroy: proc(pool: rawptr),
	make_entry:   proc(pool: rawptr) -> Pool_Entry,
	each_alive:   proc(pool: rawptr, fn: proc(comp: rawptr)),

	// lifecycle thunks (nil = component doesn't provide it)
	reset:       proc(comp: rawptr),
	cleanup:     proc(comp: rawptr),
	on_validate: proc(comp: rawptr),
	on_destroy:  proc(comp: rawptr),
}

// Serialized external components are plain component objects (same shape as
// the typed arrays: base local_id/enabled + fields) carrying one extra key,
// EXT_TYPE_KEY, holding the component's type GUID (stable across builds).
// Keeping the shape identical to engine components means every JSON-level
// walker (override apply/diff/revert, lid collection) treats both the same.
EXT_TYPE_KEY :: "__type"

component_registry: map[TypeKey]Component_Desc
_component_registry_by_guid: map[uuid.Identifier]TypeKey

component_register :: proc(desc: Component_Desc) {
	{
		// The registry is process-global: it must never borrow the caller's
		// allocator (the test runner hands every test a scoped tracking allocator
		// that is torn down afterwards — a registry allocated there would dangle).
		context.allocator = runtime.default_allocator()
		component_registry[desc.type_key] = desc
		_component_registry_by_guid[desc.type_guid] = desc.type_key

		// External components participate in the same runtime lifecycle tables the
		// engine's generated init fills for engine components.
		if desc.reset != nil do type_reset_procs[desc.type_key] = desc.reset
		if desc.cleanup != nil do type_cleanup_procs[desc.type_key] = desc.cleanup
		if desc.on_validate != nil do component_on_validate_procs[desc.type_key] = desc.on_validate
		if desc.on_destroy != nil do component_on_destroy_procs[desc.type_key] = desc.on_destroy
	}

	// Outside the override block: pools belong to the WORLD and must be
	// allocated under the caller's allocator — world destroy frees them under
	// that same one (a default-heap pool makes the editor's debug tracking
	// allocator panic with a bad free at shutdown).
	if c := ctx_get(); c != nil && c.world != nil {
		_world_ensure_ext_pool(c.world, desc)
	}
}

// Instantiate the desc's pool in this world (idempotent). Registration order
// and world creation order are decoupled: w_init ensures pools for descs
// registered before the world existed, component_register for the current one.
_world_ensure_ext_pool :: proc(w: ^World, desc: Component_Desc) {
	if w.ext_pools[desc.type_key] != nil do return
	pool := desc.pool_create()
	w.ext_pools[desc.type_key] = pool
	w.pool_table[desc.type_key] = desc.make_entry(pool)
	// collect_fn stays nil: world_pool_collect falls back to the generic blob
	// path for registered external components.
}

// Called from generated w_init.
_w_init_ext_pools :: proc(w: ^World) {
	for _, desc in component_registry {
		_world_ensure_ext_pool(w, desc)
	}
}

// Called from generated world_destroy_all.
_world_destroy_ext :: proc(w: ^World) {
	for key, desc in component_registry {
		pool := w.ext_pools[key]
		if pool == nil do continue
		if desc.on_destroy != nil && desc.each_alive != nil {
			desc.each_alive(pool, desc.on_destroy)
		}
		if desc.pool_destroy != nil do desc.pool_destroy(pool)
		w.ext_pools[key] = nil
		w.pool_table[key] = {}
	}
}

_ext_desc_for_value :: proc(v: json.Value) -> (Component_Desc, bool) {
	obj, is_obj := v.(json.Object)
	if !is_obj do return {}, false
	tv, has_type := obj[EXT_TYPE_KEY]
	if !has_type do return {}, false
	guid_str, is_str := tv.(json.String)
	if !is_str do return {}, false
	guid, gerr := uuid.read(string(guid_str))
	if gerr != nil do return {}, false
	key, has := _component_registry_by_guid[guid]
	if !has {
		fmt.printfln("[Scene] unknown external component type %s (not registered) — skipped", string(guid_str))
		return {}, false
	}
	return component_registry[key], true
}

// json.Value -> typed component memory (ptr must point at a T of desc.tid).
_ext_value_into :: proc(desc: Component_Desc, v: json.Value, ptr: rawptr) -> bool {
	bytes, merr := json.marshal(v, {spec = .JSON}, context.temp_allocator)
	if merr != nil do return false
	pp := ptr
	uerr := json.unmarshal_any(bytes, any{&pp, desc.ptr_tid})
	return uerr == nil
}

// typed component memory -> fresh json.Value.
_ext_value_from :: proc(desc: Component_Desc, ptr: rawptr) -> (json.Value, bool) {
	bytes, merr := json.marshal(any{ptr, desc.tid}, {spec = .JSON}, context.temp_allocator)
	if merr != nil do return nil, false
	v, perr := json.parse(bytes, .JSON, true)
	if perr != nil do return nil, false
	return v, true
}

// Save path: world_pool_collect fallback for external components.
_ext_collect_component :: proc(desc: Component_Desc, comp: rawptr, sf: ^SceneFile) {
	v, ok := _ext_value_from(desc, comp)
	if !ok do return
	_ext_value_stamp_type(&v, desc)
	append(&sf.components, v)
}

// Add EXT_TYPE_KEY to a freshly parsed component object. Key and value are
// allocated so json.destroy_value can free them like any parsed member.
_ext_value_stamp_type :: proc(v: ^json.Value, desc: Component_Desc) {
	obj, is_obj := v.(json.Object)
	if !is_obj do return
	key := strings.clone(EXT_TYPE_KEY)
	obj[key] = json.String(uuid.to_string(desc.type_guid))
	v^ = obj
}

// Load path: create pool instances for every component record. Returns
// local_id -> handle (temp allocator). Records whose guid has no registered
// desc are STASHED on `s` (when given) instead of dropped — they re-emit on
// save so a binary without that package can't destroy the data
// (Unity's missing-script behavior). Nested-prefab
// loads pass s == nil here: their records live in the prefab FILE, which host
// saves never rewrite.
_scene_load_ext_components :: proc(sf: ^SceneFile, s: ^Scene = nil) -> map[Local_ID]Handle {
	w := ctx_world()
	out := make(map[Local_ID]Handle, context.temp_allocator)
	for &v in sf.components {
		desc, ok := _ext_desc_for_value(v)
		if !ok {
			_stash_unknown_component(sf, s, v)
			continue
		}
		_world_ensure_ext_pool(w, desc)
		handle, ptr := world_pool_create(w, desc.type_key)
		if ptr == nil do continue
		if !_ext_value_into(desc, v, ptr) {
			// The type IS registered but the record won't parse into it
			// (corrupt/incompatible field). Dropping it silently loses data on
			// the next save — preserve it verbatim exactly like an unknown type.
			guid_str := "?"
			if tv, has := v.(json.Object); has {
				if gs, ok := tv[EXT_TYPE_KEY].(json.String); ok do guid_str = string(gs)
			}
			log.errorf("[Scene] Component %s failed to parse into its registered type — preserved verbatim, not loaded", guid_str)
			world_pool_destroy(w, handle)
			_stash_unknown_component(sf, s, v)
			continue
		}
		base := cast(^CompData)ptr
		out[base.local_id] = handle
	}
	return out
}

// Preserve an unresolvable record: clone it plus the lid of the transform
// whose components list references it. Records with no owner in the file are
// orphans and stay dropped.
_stash_unknown_component :: proc(sf: ^SceneFile, s: ^Scene, v: json.Value) {
	if s == nil do return
	obj, is_obj := v.(json.Object)
	if !is_obj do return
	lid, lid_ok := _json_local_id_of(obj)
	if !lid_ok || lid == 0 do return
	for &tr in sf.transforms {
		for c in tr.components {
			if c.local_id != lid do continue
			guid_str := "?"
			if tv, has := obj[EXT_TYPE_KEY]; has {
				if gs, is_str := tv.(json.String); is_str do guid_str = string(gs)
			}
			log.warningf("[Scene] Unknown component type %s (lid %d) — preserved, not loaded (package missing?)", guid_str, lid)
			append(&s.unknown_components, Unknown_Component{
				owner_lid = tr.local_id,
				local_id  = lid,
				value     = json.clone_value(v),
			})
			return
		}
	}
}

_ext_set_owner :: proc(w: ^World, h: Handle, owner: Transform_Handle) {
	ptr := world_pool_get(w, h)
	if ptr != nil do (cast(^CompData)ptr).owner = owner
}

_ext_resolve_refs :: proc(w: ^World, h: Handle, s: ^Scene, file_local: ^map[Local_ID]Handle = nil) {
	desc, ok := component_registry[h.type_key]
	if !ok do return
	ptr := world_pool_get(w, h)
	if ptr != nil do _resolve_refs_in_value(ptr, type_info_of(desc.tid), s, file_local)
}

// Remap support for scene paste/instantiate. Records are round-tripped through
// a typed temp instance so local_ids AND Ref_Local/Ref fields inside the blob
// go through the exact machinery typed components use. Two phases because the
// generated remap assigns new ids for all objects first (transform component
// lists need them) and rewrites refs last, when the remap table is complete.
_Ext_Remap_Temp :: struct {
	desc: Component_Desc,
	ptr:  rawptr,
	val:  ^json.Value,
}

_scene_file_remap_ext_begin :: proc(sf: ^SceneFile, s: ^Scene, remap: ^map[Local_ID]Local_ID, mapper: proc(user: rawptr, old: Local_ID) -> Local_ID = nil, user: rawptr = nil) -> [dynamic]_Ext_Remap_Temp {
	temps := make([dynamic]_Ext_Remap_Temp, context.temp_allocator)
	for &v in sf.components {
		desc, ok := _ext_desc_for_value(v)
		if !ok do continue
		ti := type_info_of(desc.tid)
		ptr, aerr := mem.alloc(ti.size, ti.align) // zero-initialized
		if aerr != nil do continue
		if !_ext_value_into(desc, v, ptr) {
			mem.free(ptr)
			continue
		}
		base := cast(^CompData)ptr
		new_id := _remap_new_id(s, mapper, user, base.local_id)
		remap[base.local_id] = new_id
		base.local_id = new_id
		append(&temps, _Ext_Remap_Temp{desc = desc, ptr = ptr, val = &v})
	}
	return temps
}

_scene_file_remap_ext_finish :: proc(temps: [dynamic]_Ext_Remap_Temp, remap: ^map[Local_ID]Local_ID) {
	for &t in temps {
		_remap_refs_in_value(t.ptr, type_info_of(t.desc.tid), remap)
		if v, ok := _ext_value_from(t.desc, t.ptr); ok {
			_ext_value_stamp_type(&v, t.desc)
			json.destroy_value(t.val^)
			t.val^ = v
		}
		if t.desc.cleanup != nil do t.desc.cleanup(t.ptr)
		mem.free(t.ptr)
	}
}

// Called from generated scene_file_destroy.
_scene_file_destroy_ext :: proc(sf: ^SceneFile) {
	for &v in sf.components {
		json.destroy_value(v)
	}
	delete(sf.components)
}

// Rewrite each component record through its registered type: parse into the
// typed struct (missing keys default to zero), then re-marshal. The result has
// the SAME field set the LIVE struct produces on save, so an override diff of
// (normalized prefab base) vs (live content) never fires on fields the prefab
// file simply omitted (a field added to a component after the prefab was
// authored). Records whose type isn't registered pass through untouched.
// Returns fresh bytes on the temp allocator; nil bytes leaves the input unusable.
_normalize_component_records :: proc(raw: []byte, allocator := context.temp_allocator) -> ([]byte, bool) {
	// Everything below allocates on temp: the parsed tree and every rewritten
	// record are transient, freed together by the frame's free_all — no manual
	// destroy_value (mixing temp/default frees is what triggers bad-free).
	prev := context.allocator
	context.allocator = context.temp_allocator
	defer context.allocator = prev

	root, perr := json.parse(raw, .JSON, true)
	if perr != nil do return nil, false
	obj, is_obj := root.(json.Object)
	if !is_obj do return nil, false
	comps_val, has := obj["components"]
	if !has {
		out, merr := json.marshal(root, {spec = .JSON}, allocator)
		return out, merr == nil
	}
	arr, is_arr := comps_val.(json.Array)
	if !is_arr {
		out, merr := json.marshal(root, {spec = .JSON}, allocator)
		return out, merr == nil
	}

	for &rec, i in arr {
		desc, ok := _ext_desc_for_value(rec)
		if !ok do continue // unknown type: leave verbatim
		ti := type_info_of(desc.tid)
		ptr, aerr := mem.alloc(ti.size, ti.align) // zero, temp-allocated
		if aerr != nil do continue
		// Match the LOAD path exactly (world_pool_create yields a zeroed slot,
		// then _ext_value_into overwrites only present keys) — no reset, so a
		// field absent from BOTH file and live struct compares equal (zero).
		if !_ext_value_into(desc, rec, ptr) do continue // corrupt: leave verbatim
		nv, nok := _ext_value_from(desc, ptr)
		if !nok do continue
		_ext_value_stamp_type(&nv, desc)
		arr[i] = nv // old rec is temp too; freed with the tree
	}
	obj["components"] = arr

	out, merr := json.marshal(json.Value(obj), {spec = .JSON}, allocator)
	return out, merr == nil
}
