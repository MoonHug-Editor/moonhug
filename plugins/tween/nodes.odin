package tween

// The transform-targeting value nodes. Any package declares its own the same
// way (plugin_example is the reference): a struct embedding Tween and
// Tween_Anim with a `duration`, a begin proc that captures the start value, an
// apply proc that writes the value at a factor, and one register_tween call
// on the SerializationInit phase (register_builtin_nodes here). Tween_Anim owns
// its curve's keys, so the node declares a type_cleanup that frees them.
//
// The factor is 0 at the start and 1 at the end. It leaves 0..1 with the Back
// and Elastic eases and in Incremental cycles, so apply never clamps it.

import "core:math/linalg"
import engine "moonhug:packages/engine"

@(typ_guid={guid="aa1970c6-51d2-4d27-9dc8-718ad1e51160"})
TweenScaleToLocal :: struct {
    using base : Tween `inline:""`,
    using anim : Tween_Anim `inline:""`,
    scale    : [3]f32,
    duration : f32,

    from     : [3]f32 `json:"-"`,
}

type_cleanup_TweenScaleToLocal :: proc(self: ^TweenScaleToLocal) {
    type_cleanup_Tween_Anim(&self.anim)
    self^ = {}
}

begin_TweenScaleToLocal :: proc(self: ^TweenScaleToLocal, ctx: TweenContext) -> bool {
    transform := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(subject_of(&self.base, ctx)))
    if transform == nil do return false
    self.from = transform.scale
    return true
}

apply_TweenScaleToLocal :: proc(self: ^TweenScaleToLocal, t: f32, ctx: TweenContext) {
    transform := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(subject_of(&self.base, ctx)))
    if transform == nil do return
    transform.scale = self.from + (self.scale - self.from) * t
}

// ---

@(typ_guid={guid="b72f3c1a-9e45-4b8d-a3f7-2d1e5c8f0b94"})
TweenRotateToLocal :: struct {
    using base : Tween `inline:""`,
    using anim : Tween_Anim `inline:""`,
    rotation : [4]f32 `inspect:"" decor:euler()`,
    duration : f32,

    from     : [4]f32 `json:"-"`,
}

type_cleanup_TweenRotateToLocal :: proc(self: ^TweenRotateToLocal) {
    type_cleanup_Tween_Anim(&self.anim)
    self^ = {}
}

begin_TweenRotateToLocal :: proc(self: ^TweenRotateToLocal, ctx: TweenContext) -> bool {
    transform := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(subject_of(&self.base, ctx)))
    if transform == nil do return false
    self.from = transform.rotation
    return true
}

apply_TweenRotateToLocal :: proc(self: ^TweenRotateToLocal, t: f32, ctx: TweenContext) {
    transform := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(subject_of(&self.base, ctx)))
    if transform == nil do return
    // A new node's `rotation` is the all-zero value, which the Euler drawer
    // shows as 0, 0, 0: no rotation, the way a scene reads an all-zero rotation.
    to := self.rotation if self.rotation != {} else engine.QUAT_IDENTITY
    transform.rotation = engine.quat_from_native(linalg.quaternion_slerp(engine.quat_to_native(self.from), engine.quat_to_native(to), t))
}

// ---

@(typ_guid={guid="da9d301a-66a3-450c-8c0b-8c696ad60b0b"})
TweenMoveToLocal :: struct {
    using base : Tween `inline:""`,
    using anim : Tween_Anim `inline:""`,
    position : [3]f32,
    duration : f32,
    // Above 0: units per second, and the duration follows from the distance.
    speed    : f32 `decor:min(0)`,

    from     : [3]f32 `json:"-"`,
}

type_cleanup_TweenMoveToLocal :: proc(self: ^TweenMoveToLocal) {
    type_cleanup_Tween_Anim(&self.anim)
    self^ = {}
}

begin_TweenMoveToLocal :: proc(self: ^TweenMoveToLocal, ctx: TweenContext) -> bool {
    transform := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(subject_of(&self.base, ctx)))
    if transform == nil do return false
    self.from = transform.position
    if self.speed > 0 do self.duration = linalg.length(self.position - self.from) / self.speed
    return true
}

apply_TweenMoveToLocal :: proc(self: ^TweenMoveToLocal, t: f32, ctx: TweenContext) {
    transform := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(subject_of(&self.base, ctx)))
    if transform == nil do return
    transform.position = self.from + (self.position - self.from) * t
}
