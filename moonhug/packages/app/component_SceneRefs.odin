package app

import "../../engine"

// References to long-lived scene objects, placed once on the scene root. Game
// code (app package) fetches the singleton via its pool and reads the resolved
// handles; engine.Ref_Local handles resolve during scene load.
//
// Points at the tank's transform (which carries the Tank component); the Tank
// itself owns the gameplay refs (turret, shoot_from, projectile prefab).
@(component={max=1})
@(typ_guid={guid = "b1d7c74d-4e52-4088-a118-85059cf80149"})
SceneRefs :: struct {
    using base: engine.CompData `inspect:"-"`,
    tank: engine.Ref_Local `ref:"Transform"`,
}

reset_SceneRefs :: proc(comp: ^SceneRefs) {
}
