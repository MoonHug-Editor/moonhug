package app

// Main: the game logic tick for the tank demo. Requires a scene with a
// SceneRefs component on its root pointing at a tank object that carries a Tank
// component (turret / shoot_from / projectile assigned in the inspector); does
// nothing in scenes without one.

import "core:math"
import rl "vendor:raylib"
import "../engine"

TANK_SPEED :: f32(5)

// Aim direction of the turret in the world XY plane, refreshed by turret_aim
// each tick and consumed by fire at spawn time.
@(private = "file")
_aim_dir: [2]f32 = {0, 1}

@(update={order=0})
game_tick :: proc(dt: f32) {
    refs := scene_refs_get()
    if refs != nil && refs.enabled {
        _, tank := get_comp(engine.Transform_Handle(refs.tank.handle), Tank)
        if tank != nil && tank.enabled {
            tank_move(tank, dt)
            turret_aim(tank)
            // Bullets parent to the scene root (SceneRefs' owner), not the tank,
            // so they don't inherit tank motion after spawn.
            fire(tank, refs.owner)
        }
    }
    projectiles_tick(dt)
}

scene_refs_get :: proc() -> ^SceneRefs {
    pool := scene_refses(engine.ctx_world())
    if pool == nil do return nil
    for i in 0..<len(pool.slots) {
        slot := &pool.slots[i]
        if slot.alive do return &slot.data
    }
    return nil
}

tank_move :: proc(tank: ^Tank, dt: f32) {
    w := engine.ctx_world()
    t := engine.pool_get(&w.transforms, engine.Handle(tank.owner))
    if t == nil do return

    if rl.IsKeyDown(.W) do t.position[1] += TANK_SPEED * dt
    if rl.IsKeyDown(.S) do t.position[1] -= TANK_SPEED * dt
    if rl.IsKeyDown(.A) do t.position[0] -= TANK_SPEED * dt
    if rl.IsKeyDown(.D) do t.position[0] += TANK_SPEED * dt
}

turret_aim :: proc(tank: ^Tank) {
    w := engine.ctx_world()
    t := engine.pool_get(&w.transforms, tank.turret.handle)
    if t == nil do return

    cam := engine.camera_active()
    if cam == nil do return

    // Mouse ray intersected with the z=0 gameplay plane.
    ray := rl.GetScreenToWorldRay(rl.GetMousePosition(), engine.camera_to_3d(cam))
    if math.abs(ray.direction.z) < 1e-6 do return
    hit_t := -ray.position.z / ray.direction.z
    if hit_t < 0 do return
    mouse_x := ray.position.x + ray.direction.x * hit_t
    mouse_y := ray.position.y + ray.direction.y * hit_t

    tw := engine.transform_world(engine.Transform_Handle(tank.turret.handle))
    dx := mouse_x - tw.position.x
    dy := mouse_y - tw.position.y
    if dx == 0 && dy == 0 do return
    inv_len := 1.0 / math.sqrt(dx*dx + dy*dy)
    _aim_dir = {dx * inv_len, dy * inv_len}

    // Barrel art points +Y, hence the -90.
    angle_deg := math.atan2(dy, dx) * math.DEG_PER_RAD
    t.rotation = engine.quat_from_euler_xyz(0, 0, angle_deg - 90)
}

fire :: proc(tank: ^Tank, spawn_parent: engine.Transform_Handle) {
    if !rl.IsMouseButtonPressed(.LEFT) && !rl.IsKeyPressed(.SPACE) do return
    if engine.asset_guid_is_empty(tank.projectile_prefab) do return

    bH := engine.scene_instantiate_guid(tank.projectile_prefab, spawn_parent)
    if bH == {} do return

    w := engine.ctx_world()
    bt := engine.pool_get(&w.transforms, engine.Handle(bH))
    if bt == nil do return

    sw := engine.transform_world(engine.Transform_Handle(tank.shoot_from.handle))
    bt.position[0] = sw.position.x
    bt.position[1] = sw.position.y
    bt.rotation = engine.quat_from_euler_xyz(0, 0, math.atan2(_aim_dir[1], _aim_dir[0]) * math.DEG_PER_RAD - 90)

    _, proj := get_comp(bH, Projectile)
    if proj != nil do proj.dir = _aim_dir
}

projectiles_tick :: proc(dt: f32) {
    w := engine.ctx_world()
    pool := projectiles(w)
    if pool == nil do return
    for i in 0..<len(pool.slots) {
        slot := &pool.slots[i]
        if !slot.alive do continue
        p := &slot.data
        if !p.enabled do continue

        t := engine.pool_get(&w.transforms, engine.Handle(p.owner))
        if t == nil do continue
        t.position[0] += p.dir[0] * p.speed * dt
        t.position[1] += p.dir[1] * p.speed * dt
    }
}
