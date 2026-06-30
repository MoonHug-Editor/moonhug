package engine

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:path/filepath"

MAX_SCENES :: 100
Scene_ID :: i16

scene_lib: map[Asset_GUID][]byte

// Pre-baked, fully-unpacked subtree bytes per prefab GUID. Built lazily on the
// first runtime instantiate (scene_instantiate_guid) by going through nested
// resolve + unpack once, then snapshotting the flat result. Subsequent
// instantiates of the same prefab skip the resolve work entirely and just
// scene_paste_subtree the cached bytes.
@(private)
scene_lib_unpacked_cache: map[Asset_GUID][]byte

SceneManager :: struct {
    loaded: [MAX_SCENES]^Scene,
    count: int,
    active_scene: Scene_ID,
}

sm_scene_get_active :: proc() -> ^Scene {
    scene_manager := ctx_scene_manager()
    idx := scene_manager.active_scene
    if idx < 0 || int(idx) >= scene_manager.count do return nil
    return scene_manager.loaded[idx]
}

sm_scene_set_active :: proc(s: ^Scene) {
    scene_manager := ctx_scene_manager()
    if s == nil {
        scene_manager.active_scene = -1
        return
    }
    for i in 0..<scene_manager.count {
        if scene_manager.loaded[i] == s {
            scene_manager.active_scene = Scene_ID(i)
            return
        }
    }
    if scene_manager.count < MAX_SCENES {
        scene_manager.loaded[scene_manager.count] = s
        scene_manager.active_scene = Scene_ID(scene_manager.count)
        scene_manager.count += 1
    }
}

sm_find_free_slot :: proc() -> Scene_ID {
    scene_manager := ctx_scene_manager()
    for i in 0..<MAX_SCENES {
        if scene_manager.loaded[i] == nil {
            return Scene_ID(i)
        }
    }
    return -1
}

sm_scene_unload :: proc(scene: ^Scene) {
    if scene == nil do return
    if !sm_scene_is_valid(scene) do return
    scene_manager := ctx_scene_manager()

    for i in 0..<scene_manager.count {
        if scene_manager.loaded[i] == scene {
            scene_destroy(scene)
            scene_manager.loaded[i] = nil
            if scene_manager.active_scene == Scene_ID(i) {
                scene_manager.active_scene = -1
            }
            break
        }
    }
}

sm_scene_destroy_or_unload :: proc(scene: ^Scene) {
	if scene == nil do return
	scene_manager := ctx_scene_manager()
	for i in 0 ..< scene_manager.count {
		if scene_manager.loaded[i] == scene {
			sm_scene_unload(scene)
			return
		}
	}
	scene_destroy(scene)
}

sm_scene_is_valid :: proc(scene: ^Scene) -> bool {
    return scene != nil && scene.generation > 0
}

sm_scene_invalidate :: proc(scene: ^Scene) {
    if scene == nil do return
    scene.generation = 0
}

_scene_load_single :: proc(scene_file: ^SceneFile, scene_asset_guid: Asset_GUID = {}) -> ^Scene {
    scene_manager := ctx_scene_manager()
    for i in 0..<scene_manager.count {
        if scene_manager.loaded[i] != nil {
            sm_scene_unload(scene_manager.loaded[i])
        }
    }
    scene_manager.count = 0
    scene_manager.active_scene = -1
    return _scene_load_additive(scene_file, scene_asset_guid)
}

// A variant's root NS: transform_parent == 0, not pulled in from an inner
// prefab (expand_parent == {}). Returns the first such record in `s`, or nil.
_scene_find_root_variant_ns :: proc(s: ^Scene) -> ^NestedScene {
    if s == nil do return nil
    for &ns in s.nested_scenes {
        if ns.transform_parent == 0 && ns.expand_parent == {} {
            return &ns
        }
    }
    return nil
}

// Materializes a top-level variant: the base prefab becomes this scene's root.
// Bakes the base with the variant's own overrides, loads it so the base root is
// the (native) scene root with nested-owned descendants, rebinds the root NS to
// be hosted by the base root (so its overrides are the editable set, exactly
// like a normal nested scene), and grafts the variant's additions under it.
// Returns the base root handle (the new scene root), or {} on failure.
_variant_materialize_root :: proc(s: ^Scene, root_ns: ^NestedScene, file_root_lid: Local_ID) -> Transform_Handle {
    w := ctx_world()
    guid := root_ns.source_prefab
    if guid == (Asset_GUID{}) do return {}

    // Resolve the base (recursively flattening if the base is itself a variant),
    // then bake THIS variant's own overrides onto it. The base content becomes
    // the baked baseline; the root NS's overrides stay live (editable).
    base_bytes, base_owned := _prefab_resolved_bytes(guid)
    if base_bytes == nil do return {}
    defer if base_owned do delete(base_bytes)

    baked := nested_scene_apply_overrides(base_bytes, root_ns.overrides[:], guid)
    baked_owned := raw_data(baked) != raw_data(base_bytes)
    defer if baked_owned do delete(baked)

    base_sf: SceneFile
    if json.unmarshal(baked, &base_sf) != nil do return {}
    defer scene_file_destroy(&base_sf)

    base_root_lid := base_sf.root
    // Capture the NS by local_id: _scene_load_as_child appends to s.nested_scenes
    // and may reallocate it, dangling the `root_ns` pointer. Re-fetch after and
    // use `rns` for all post-append access (root_ns is a param, can't reassign).
    root_ns_lid := root_ns.local_id
    nested_before := len(s.nested_scenes)
    base_root_tH := _scene_load_as_child(&base_sf, {}, s, guid, true)
    if base_root_tH == {} do return {}
    rns, rns_ok := _find_ns_by_local_id(s, root_ns_lid)
    if !rns_ok do return {}
    rns.source_root_id = base_root_lid

    // Base content is the baked baseline: mark descendants nested-owned (NOT the
    // base root transform itself — it is this scene's native root). The base
    // root belongs to THIS scene now, so retag its scope guid to the variant's
    // (otherwise the hierarchy/host checks reject it as foreign content). Its
    // COMPONENTS, however, are inherited baseline — mark them nested-owned so
    // overrides on the root's components are captured on save like child ones.
    br := pool_get(&w.transforms, Handle(base_root_tH))
    if br != nil {
        br.scene_asset_guid = s.asset_guid
        for &c in br.components {
            raw := world_pool_get(w, c.handle)
            if raw != nil do (cast(^CompData)raw).nested_owned = true
        }
        for child in br.children do _mark_subtree_nested_owned(Transform_Handle(child.handle))
    }
    // Inner NSs the base pulled in are anchored to the base subtree.
    for i in nested_before..<len(s.nested_scenes) {
        if s.nested_scenes[i].expand_parent == {} {
            s.nested_scenes[i].expand_parent = base_root_tH
        }
    }

    // The root NS is now hosted by the base root (ordinary hosted NS). Save
    // writes transform_parent back to 0 (nested_scene_is_root_variant).
    br = pool_get(&w.transforms, Handle(base_root_tH))
    if br != nil {
        rns.transform_parent = br.local_id
        nested_scene_attach_host_breadcrumb(s, rns, br.local_id)
    }

    // Graft the variant's own additions (loaded rootless because their parent
    // lid == the base root lid the variant file lacks) under the base root.
    // Collect first, then graft in local_id order: the slot scan visits in
    // arbitrary slot order, which is not stable across save+reload and made the
    // additions' sibling order drift. local_id is persisted and stable, so
    // ordering by it keeps siblings in a fixed order every reload.
    if br != nil {
        added: [dynamic]Transform_Handle
        defer delete(added)
        for i in 0..<len(w.transforms.slots) {
            slot := &w.transforms.slots[i]
            if !slot.alive do continue
            at := &slot.data
            if at.scene != s || at.nested_owned do continue
            atH := Transform_Handle(Handle{index = u32(i), generation = slot.generation, type_key = .Transform})
            if atH == base_root_tH do continue
            if pool_valid(&w.transforms, at.parent.handle) do continue
            if at.parent.pptr.local_id != base_root_lid do continue
            append(&added, atH)
        }
        slice.sort_by(added[:], proc(a, b: Transform_Handle) -> bool {
            w := ctx_world()
            ta := pool_get(&w.transforms, Handle(a))
            tb := pool_get(&w.transforms, Handle(b))
            if ta == nil || tb == nil do return false
            return ta.local_id < tb.local_id
        })
        for atH in added {
            at := pool_get(&w.transforms, Handle(atH))
            if at == nil do continue
            at.parent = make_transform_ref(base_root_tH)
            br = pool_get(&w.transforms, Handle(base_root_tH))
            if br != nil do append(&br.children, Ref{ pptr = PPtr{local_id = at.local_id}, handle = Handle(atH) })
        }
    }
    return base_root_tH
}

_scene_load_additive :: proc(scene_file: ^SceneFile, scene_asset_guid: Asset_GUID = {}) -> ^Scene {
    scene_manager := ctx_scene_manager()
    s := scene_new()
    s.next_local_id = scene_file.next_local_id
    s.asset_guid = scene_asset_guid

    root_tH := _scene_load_as_child(scene_file, {}, s)

    // A variant's root is a NestedScene with transform_parent == 0 — the file
    // names the base root lid as sf.root but contains no such transform, so
    // _scene_load_as_child returns {}. Materialize the variant: the BASE root
    // becomes this scene's (native) root, the base's descendants are nested-
    // owned baked baseline, the variant's own overrides stay live on the root
    // NS (the editable set), and the variant's additions graft under the base.
    is_variant_root := false
    if root_tH == {} {
        if root_ns := _scene_find_root_variant_ns(s); root_ns != nil {
            root_tH = _variant_materialize_root(s, root_ns, scene_file.root)
            is_variant_root = root_tH != {}
        }
    }

    if root_tH != {} {
        scene_set_root(s, root_tH)
    } else {
        scene_ensure_root(s)
    }

    slot := sm_find_free_slot()
    if slot < 0 {
        fmt.printf("[SceneManager] No free scene slots\n")
        scene_destroy(s)
        return nil
    }

    scene_manager.loaded[slot] = s
    if int(slot) >= scene_manager.count {
        scene_manager.count = int(slot) + 1
    }

    if scene_manager.active_scene < 0 {
        scene_manager.active_scene = slot
    }

    if root_tH != {} {
        if is_variant_root {
            // The variant root NS is already materialized by
            // _variant_materialize_root; resolving the root again would
            // double-resolve. Resolve only its children (deeper nesting +
            // additions that themselves nest).
            rt := pool_get(&ctx_world().transforms, Handle(root_tH))
            if rt != nil {
                kids := make([]Ref, len(rt.children), context.temp_allocator)
                copy(kids, rt.children[:])
                for child in kids do _scene_resolve_nested_in_subtree(Transform_Handle(child.handle))
            }
            // The root NS's SHALLOW overrides were baked at materialize time, but
            // its DEEP overrides (targeting content inside the base's own nested
            // prefabs) must be patched onto the now-resolved live tree — the same
            // post-resolve pass nested_scene_resolve runs for ordinary hosts.
            // Post-materialize the root NS has transform_parent == base root lid
            // (not 0), so find it via nested_scene_is_root_variant, not the
            // pre-materialize _scene_find_root_variant_ns.
            for &ns in s.nested_scenes {
                if nested_scene_is_root_variant(s, &ns) {
                    nested_scene_apply_deep_overrides_live(root_tH, &ns)
                    break
                }
            }
        } else {
            _scene_resolve_nested_in_subtree(root_tH)
        }
        _scene_resolve_breadcrumb_targets(s)
    }
    return s
}

// After nested resolve materializes inner subtrees, walk every Breadcrumb that
// represents a cross-scene reference (scene_source.guid is non-empty — host
// pegs have empty guid) and migrate its bimap entry from the synthetic
// placeholder to the real runtime Handle of its target. Then re-run
// _resolve_refs_in_value over every pooled component so any Ref_Local field
// whose serialized lid matches a breadcrumb's lid binds to the real handle.
@(private)
_scene_resolve_breadcrumb_targets :: proc(s: ^Scene) {
    if s == nil do return
    w := ctx_world()
    migrated := false
    for lid, bc in s.breadcrumb_data {
        if pptr_guid_is_empty(bc.scene_source.guid) do continue
        real := nested_resolve_breadcrumb_to_handle(s, bc)
        if real == {} do continue
        bimap_remove_by_key(&s.local_ids, lid)
        bimap_insert(&s.local_ids, lid, real)
        migrated = true
    }
    if !migrated do return

    for i in 0 ..< len(w.transforms.slots) {
        slot := &w.transforms.slots[i]
        if !slot.alive do continue
        if slot.data.scene != s do continue
        for c in slot.data.components {
            if c.handle.type_key == INVALID_TYPE_KEY do continue
            raw := world_pool_get(w, c.handle)
            if raw == nil do continue
            tid := get_typeid_by_type_key(c.handle.type_key)
            if tid == nil do continue
            _resolve_refs_in_value(raw, type_info_of(tid), s)
        }
    }
}

sm_shutdown :: proc() {
    scene_manager := ctx_scene_manager()
    for i in 0..<scene_manager.count {
        if scene_manager.loaded[i] != nil {
            scene_destroy(scene_manager.loaded[i])
            scene_manager.loaded[i] = nil
        }
    }
    scene_manager.count = 0
    scene_manager.active_scene = -1
}

scene_lib_shutdown :: proc() {
	for _, data in scene_lib {
		delete(data)
	}
	delete(scene_lib)
	scene_lib = make(map[Asset_GUID][]byte)

	for _, data in scene_lib_unpacked_cache {
		delete(data)
	}
	delete(scene_lib_unpacked_cache)
	scene_lib_unpacked_cache = make(map[Asset_GUID][]byte)
}

// Drops the cached unpacked snapshot for `guid`. Call when the prefab source
// changes (e.g., user saves an edit to the .scene file) so the next runtime
// instantiate picks up the new content. Editor-side instantiation uses
// scene_instantiate_guid_nested, which doesn't touch this cache.
scene_lib_unpacked_invalidate :: proc(guid: Asset_GUID) {
	if data, ok := scene_lib_unpacked_cache[guid]; ok {
		delete(data)
		delete_key(&scene_lib_unpacked_cache, guid)
	}
}

scene_lib_register :: proc(guid: Asset_GUID) -> bool {
	if _, ok := scene_lib[guid]; ok {
		return true
	}
	path, ok := asset_db_get_path(uuid.Identifier(guid))
	if !ok do return false
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return false
	scene_lib[guid] = data
	return true
}

// Runtime spawn: instantiates a prefab as a flat (unpacked) transform tree
// under `parent`. The first call for a given GUID does the full nested
// resolve + unpack and snapshots the result into scene_lib_unpacked_cache;
// every subsequent call just scene_paste_subtree's the cached bytes — no
// resolve, no override application, no NS bookkeeping at runtime.
scene_instantiate_guid :: proc(guid: Asset_GUID, parent: Transform_Handle) -> Transform_Handle {
    if parent == {} do return {}

    if cached, has := scene_lib_unpacked_cache[guid]; has {
        return scene_paste_subtree(cached, parent)
    }

    host_tH := scene_instantiate_guid_nested(guid, parent)
    if host_tH == {} do return {}
    nested_scene_unpack_subtree(host_tH)

    if bytes := scene_copy_subtree(host_tH); bytes != nil {
        scene_lib_unpacked_cache[guid] = bytes
    }
    return host_tH
}

// Editor spawn: instantiates a prefab as a NestedScene reference under
// `parent`. Keeps NS metadata and `nested_owned` flags so the editor can show
// override badges, capture edits as overrides on save, etc.
scene_instantiate_guid_nested :: proc(guid: Asset_GUID, parent: Transform_Handle) -> Transform_Handle {
    if !scene_lib_register(guid) do return {}
    w := ctx_world()
    pt := pool_get(&w.transforms, Handle(parent))
    if pt == nil do return {}
    sc := pt.scene
    if sc == nil do return {}

    // Inheritance (variant base, transform_parent==0) and composition (nested
    // instance, transform_parent!=0) are separate concepts (Unity: Prefab Variant
    // vs Nested Prefab). This is the COMPOSITION entry point. Unity forbids the
    // cross-concept loop where composition closes an inheritance chain — e.g.
    // nesting bullet_Variant inside bullet when bullet_Variant's base IS bullet
    // (bullet would re-expand a variant of itself forever). Reject when either
    // side inherits from the other along the variant base chain. Plain instance
    // nesting (a second `c` under bullet) is fine and allowed, as in Unity.
    if sc.asset_guid != (Asset_GUID{}) && guid != sc.asset_guid {
        if _prefab_inherits_from(guid, sc.asset_guid) || _prefab_inherits_from(sc.asset_guid, guid) {
            fmt.printf("[NestedScene] refusing to nest %v into scene %v — would close an inheritance cycle (Unity forbids nesting a variant of an ancestor)\n", guid, sc.asset_guid)
            return {}
        }
    }

    name := ""
    if path, ok := asset_db_get_path(uuid.Identifier(guid)); ok {
        name = filepath.stem(path)
    }

    host_tH := transform_new(name, parent)
    if host_tH == {} do return {}

    // Seed host's local scale/rotation from the prefab's root transform.
    // After resolve, the prefab's root transform is destroyed and its content
    // absorbed into the host; without this, the host keeps transform_new's
    // identity defaults and a scaled/rotated prefab (e.g., bullet's [0.1] root
    // scale) renders at the wrong size. Position is left at 0 so callers can
    // place the instance in the world.
    if root_scale, root_rot, ok := _prefab_raw_root_scale_rotation(guid); ok {
        if ht := pool_get(&w.transforms, Handle(host_tH)); ht != nil {
            ht.scale = root_scale
            ht.rotation = root_rot
        }
    }

    pt = pool_get(&w.transforms, Handle(parent))
    sibling_idx := len(pt.children) - 1
    if nested_scene_add(sc, guid, host_tH, sibling_idx) == nil {
        transform_destroy(host_tH)
        return {}
    }
    nested_scene_resolve(host_tH)
    return host_tH
}

// True if prefab `guid` IS `needle` or, transitively, INHERITS from `needle`
// (its variant base chain — the transform_parent==0 NS — leads back to needle).
// Used to reject nesting cycles: nesting a variant of X inside X re-expands X
// forever. Instance-nesting (nesting the same prefab as a sibling) is NOT a
// cycle and is allowed — only inheritance is followed here, not every nested
// instance. Bounded by a depth guard against already-corrupt data.
@(private)
_prefab_inherits_from :: proc(guid: Asset_GUID, needle: Asset_GUID, depth := 0) -> bool {
    if guid == needle do return true
    if depth > 32 do return false
    if !scene_lib_register(guid) do return false
    raw, has := scene_lib[guid]
    if !has do return false

    sf: SceneFile
    cpy := make([]byte, len(raw), context.temp_allocator)
    copy(cpy, raw)
    if json.unmarshal(cpy, &sf) != nil do return false
    defer scene_file_destroy(&sf)

    // Follow ONLY the variant base (the root NS with transform_parent == 0).
    for &ns in sf.nested_scenes {
        if ns.transform_parent != 0 do continue
        if ns.source_prefab == (Asset_GUID{}) do continue
        return _prefab_inherits_from(ns.source_prefab, needle, depth + 1)
    }
    return false
}

@(private)
_prefab_raw_root_scale_rotation :: proc(guid: Asset_GUID) -> (scale: [3]f32, rotation: [4]f32, ok: bool) {
    raw, has := scene_lib[guid]
    if !has do return {1, 1, 1}, QUAT_IDENTITY, false
    sf: SceneFile
    if err := json.unmarshal(raw, &sf); err != nil do return {1, 1, 1}, QUAT_IDENTITY, false
    defer scene_file_destroy(&sf)
    for &t in sf.transforms {
        if t.local_id == sf.root {
            r := t.rotation
            if r == {0, 0, 0, 0} do r = QUAT_IDENTITY
            return t.scale, r, true
        }
    }
    return {1, 1, 1}, QUAT_IDENTITY, false
}
