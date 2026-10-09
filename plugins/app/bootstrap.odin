package app

import "core:encoding/uuid"
import "moonhug:packages/engine"

// Game-side startup. Registers prefabs the game spawns at runtime.
@(phase={key=Phase.Init})
game_bootstrap :: proc() {
    bullet_guid, err := uuid.read(BULLET_SCENE_GUID)
    if err == nil {
        engine.scene_lib_register(engine.Asset_GUID(bullet_guid))
    }
}

// After a gameplay scene is live: the boot scene, a demo the menu loads, the
// editor's play start. Ref_Local handles (incl. SceneRefs) resolve during
// the load itself; this is for setup that needs live scene objects.
@(phase={key=Phase.SceneLoaded})
scene_loaded :: proc() {
    setup_player_animations()
}
