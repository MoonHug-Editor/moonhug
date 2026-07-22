package app

import "../../engine"

// Straight-line mover: flies along dir at speed until its Lifetime expires.
// dir is set by game code at spawn (not authored), speed is authored.
@(component)
@(typ_guid={guid = "7f5e6f68-938f-467f-993e-4d92adb25233"})
Projectile :: struct {
    using base: engine.CompData `inspect:"-"`,
    speed: f32,
    dir:   [2]f32 `inspect:"-"`,
}

reset_Projectile :: proc(comp: ^Projectile) {
    comp.speed = 3
}
