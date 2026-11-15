package tween

// Shake and punch: a motion around where the object is that fades out and
// leaves it where it was.
//
//   tween.shake_position(camera, {0.3, 0.3, 0}, 0.4)
//   tween.punch_scale(button, {0.2, 0.2, 0}, 0.25)
//
// - A shake wobbles on every axis that has strength, each axis on its own.
// - A punch swings along the strength: out, back through the start, and again
//   smaller.
// - `strength` is the largest offset: units for position, degrees for
//   rotation, scale for scale.
// - `frequency` is swings per second.
// - The motion is the same every time for the same arguments.

import "core:math"
import engine "moonhug:packages/engine"

Shake_Part :: enum u8 {
    Position,
    Rotation,
    Scale,
}

// A shake or a punch. A tree authors it, and shake_position and the others
// make it from code.
@(typ_guid={guid="f96f6958-de3a-41e7-8035-8756fec359ac"})
TweenShake :: struct {
    using base: Tween `inline:""`,
    using anim: Tween_Anim `inline:""`,
    duration: f32,

    part:      Shake_Part,
    // A swing along the strength, in place of a wobble on every axis.
    punch:     bool,
    // The largest offset: units for position, degrees for rotation.
    strength:  [3]f32,
    // Swings per second.
    frequency: f32 `decor:min(0)`,
    from:      [4]f32 `json:"-" inspect:"-"`,
}

type_reset_TweenShake :: proc(self: ^TweenShake) {
    self.strength = {0.3, 0.3, 0}
    self.frequency = 10
    self.duration = 0.5
}

type_cleanup_TweenShake :: proc(self: ^TweenShake) {
    type_cleanup_Tween_Anim(&self.anim)
    self^ = {}
}

begin_TweenShake :: proc(self: ^TweenShake, ctx: TweenContext) -> bool {
    transform := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(subject_of(&self.base, ctx)))
    if transform == nil do return false
    switch self.part {
    case .Position: self.from.xyz = transform.position
    case .Rotation: self.from = transform.rotation
    case .Scale:    self.from.xyz = transform.scale
    }
    return true
}

apply_TweenShake :: proc(self: ^TweenShake, t: f32, ctx: TweenContext) {
    transform := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(subject_of(&self.base, ctx)))
    if transform == nil do return
    // The swing dies out to nothing at the end, so the object is back.
    fade := clamp(1 - t, 0, 1)
    phase := t * self.duration * self.frequency * math.TAU
    offset: [3]f32
    if self.punch {
        offset = self.strength * (math.sin(phase) * fade)
    } else {
        // Two sines per axis with unrelated periods and starts: uneven enough
        // to read as a shake, and the same on every run.
        for i in 0 ..< 3 {
            k := f32(i)
            wobble := 0.6 * math.sin(phase * (1 + 0.13 * k) + 1.7 * k) + 0.4 * math.sin(phase * (1.9 + 0.21 * k) + 4.1 * k + 0.5)
            offset[i] = self.strength[i] * wobble * fade
        }
    }
    switch self.part {
    case .Position:
        transform.position = self.from.xyz + offset
    case .Scale:
        transform.scale = self.from.xyz + offset
    case .Rotation:
        swing := engine.quat_to_native(engine.quat_from_euler_xyz(offset.x, offset.y, offset.z))
        transform.rotation = engine.quat_from_native(engine.quat_to_native(self.from) * swing)
    }
}

shake_position :: proc(target: engine.Transform_Handle, strength: [3]f32, duration: f32, frequency: f32 = 10, opt := Options{}) -> Handle {
    return _shake(target, .Position, false, strength, duration, frequency, opt)
}

// `strength` is degrees around each local axis.
shake_rotation :: proc(target: engine.Transform_Handle, strength: [3]f32, duration: f32, frequency: f32 = 10, opt := Options{}) -> Handle {
    return _shake(target, .Rotation, false, strength, duration, frequency, opt)
}

shake_scale :: proc(target: engine.Transform_Handle, strength: [3]f32, duration: f32, frequency: f32 = 10, opt := Options{}) -> Handle {
    return _shake(target, .Scale, false, strength, duration, frequency, opt)
}

punch_position :: proc(target: engine.Transform_Handle, strength: [3]f32, duration: f32, frequency: f32 = 4, opt := Options{}) -> Handle {
    return _shake(target, .Position, true, strength, duration, frequency, opt)
}

// `strength` is degrees around each local axis.
punch_rotation :: proc(target: engine.Transform_Handle, strength: [3]f32, duration: f32, frequency: f32 = 4, opt := Options{}) -> Handle {
    return _shake(target, .Rotation, true, strength, duration, frequency, opt)
}

punch_scale :: proc(target: engine.Transform_Handle, strength: [3]f32, duration: f32, frequency: f32 = 4, opt := Options{}) -> Handle {
    return _shake(target, .Scale, true, strength, duration, frequency, opt)
}

@(private = "file")
_shake :: proc(target: engine.Transform_Handle, part: Shake_Part, punch: bool, strength: [3]f32, duration, frequency: f32, opt: Options) -> Handle {
    assert(opt.speed == 0, "tween: a shake has no speed option, give a duration")
    h, node := node_new(TweenShake)
    node.part = part
    node.punch = punch
    node.strength = strength
    node.frequency = frequency
    node.duration = duration
    return start_value_node(h, &node.base, &node.anim, target, .Linear, opt)
}
