package app

import "moonhug:engine"

// The tank: gameplay component holding references to its own moving parts and
// the projectile it fires. Lives on the tank object. SceneRefs (on the scene
// root) points the game loop at this component.
@(component)
@(typ_guid={guid = "f15b003c-a491-4aec-b838-49e641a25346"})
Tank :: struct {
    using base: engine.CompData `inspect:"-"`,
    turret:            engine.Ref_Local `ref:"Transform"`,
    shoot_from:        engine.Ref_Local `ref:"Transform"`,
    projectile_prefab: engine.Asset_GUID `ref:"Transform"`,
    ref_example:       engine.Ref `ref:"SpriteRenderer"`,
}

reset_Tank :: proc(comp: ^Tank) {
}
