package engine

import "core:fmt"
import "core:os"
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

_scene_load_additive :: proc(scene_file: ^SceneFile, scene_asset_guid: Asset_GUID = {}) -> ^Scene {
    scene_manager := ctx_scene_manager()
    s := scene_new()
    s.next_local_id = scene_file.next_local_id
    s.asset_guid = scene_asset_guid

    root_tH := _scene_load_as_child(scene_file, {}, s)
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
        _scene_resolve_nested_in_subtree(root_tH)
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
