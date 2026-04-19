package engine

import "core:fmt"
import "core:os"
import "core:encoding/json"
import "core:encoding/uuid"

MAX_SCENES :: 100
Scene_ID :: i16

scene_lib: map[Asset_GUID][]byte

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

sm_scene_is_valid :: proc(scene: ^Scene) -> bool {
    return scene != nil && scene.generation > 0
}

sm_scene_invalidate :: proc(scene: ^Scene) {
    if scene == nil do return
    scene.generation = 0
}

_scene_load_single :: proc(scene_file: ^SceneFile) -> ^Scene {
    scene_manager := ctx_scene_manager()
    for i in 0..<scene_manager.count {
        if scene_manager.loaded[i] != nil {
            sm_scene_unload(scene_manager.loaded[i])
        }
    }
    scene_manager.count = 0
    scene_manager.active_scene = -1
    return _scene_load_additive(scene_file)
}

_scene_load_additive :: proc(scene_file: ^SceneFile) -> ^Scene {
    scene_manager := ctx_scene_manager()
    s := scene_new()
    s.next_local_id = scene_file.next_local_id

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
        if ctx_get().is_playmode {
            _scene_expand_nested_in_subtree(root_tH)
        } else {
            _scene_resolve_nested_in_subtree(root_tH)
        }
    }
    return s
}

scene_lib_register :: proc(guid: Asset_GUID) -> bool {
    path, ok := asset_db_get_path(uuid.Identifier(guid))
    if !ok do return false
    data, err := os.read_entire_file(path, context.allocator)
    if err != nil do return false
    scene_lib[guid] = data
    return true
}

scene_instantiate_guid :: proc(guid: Asset_GUID, parent: Transform_Handle) -> Transform_Handle {
    raw, ok := scene_lib[guid]
    if !ok do return {}
    sf: SceneFile
    if err := json.unmarshal(raw, &sf); err != nil do return {}
    defer scene_file_destroy(&sf)
    w := ctx_world()
    tr := pool_get(&w.transforms, Handle(parent))
    sc: ^Scene
    if tr != nil do sc = tr.scene
    _scene_file_remap_local_ids(&sf, sc)
    return _scene_load_as_child(&sf, parent, sc)
}
