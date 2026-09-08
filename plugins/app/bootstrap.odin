package app

import "core:encoding/uuid"
import "moonhug:engine"

// Game-side startup, separate from the generic app plumbing in app_init
// (order=1 runs after it). Registers prefabs the game spawns at runtime.
@(phase={key=Phase.Init, order=1})
game_bootstrap :: proc() {
    bullet_guid, err := uuid.read(BULLET_SCENE_GUID)
    if err == nil {
        engine.scene_lib_register(engine.Asset_GUID(bullet_guid))
    }
}

// Call after a gameplay scene is loaded into the world. Ref_Local handles
// (incl. SceneRefs) resolve during the load itself; this is for setup that
// needs live scene objects.
scene_loaded :: proc() {
    setup_player_animations()
}
