package engine

import "core:fmt"

MAX_SCENES :: 100
Scene_ID :: i16

SceneManager :: struct {
    loaded: [MAX_SCENES]^Scene,
    count: int,
    active_scene: Scene_ID,
}

sm_get_active_scene :: proc() -> ^Scene {
    scene_manager := ctx_scene_manager()
    idx := scene_manager.active_scene
    if idx < 0 || int(idx) >= scene_manager.count do return nil
    return scene_manager.loaded[idx]
}

sm_set_active_scene :: proc(s: ^Scene) {
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

scene_unload :: proc(scene: ^Scene) {
    if scene == nil do return
    if !scene_is_valid(scene) do return
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

scene_is_valid :: proc(scene: ^Scene) -> bool {
    return scene != nil && scene.generation > 0
}

scene_invalidate :: proc(scene: ^Scene) {
    if scene == nil do return
    scene.generation = 0
}

scene_load_single :: proc(scene_file: ^SceneFile) -> ^Scene {
    scene_manager := ctx_scene_manager()
    for i in 0..<scene_manager.count {
        if scene_manager.loaded[i] != nil {
            scene_unload(scene_manager.loaded[i])
        }
    }
    scene_manager.count = 0
    scene_manager.active_scene = -1
    return scene_load_additive(scene_file)
}

scene_load_additive :: proc(scene_file: ^SceneFile) -> ^Scene {
    scene_manager := ctx_scene_manager()
    s := scene_new()
    s.next_local_id = scene_file.next_local_id

    root_tH := scene_load_as_child(scene_file, {}, s)
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
    return s
}

scene_instantiate :: proc(scene_file: ^SceneFile, parent: Transform_Handle) -> Transform_Handle {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(parent))
    s: ^Scene
    if t != nil do s = t.scene
    return scene_load_as_child(scene_file, parent, s)
}
