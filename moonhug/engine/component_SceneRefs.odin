package engine

// References to long-lived scene objects, placed once on the scene root.
// Game code (app package) fetches the singleton via its pool and reads the
// resolved handles; Ref_Local handles resolve during scene load.
@(component={max=1})
@(typ_guid={guid = "b1d7c74d-4e52-4088-a118-85059cf80149"})
SceneRefs :: struct {
    using base: CompData `inspect:"-"`,
    tank:              Ref_Local `ref:"Transform"`,
    turret:            Ref_Local `ref:"Transform"`,
    shoot_from:        Ref_Local `ref:"Transform"`,
    projectile_prefab: Asset_GUID,
}

reset_SceneRefs :: proc(comp: ^SceneRefs) {
}
