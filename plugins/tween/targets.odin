package tween

// More to animate than local position, scale and rotation.
//
// - World space: world_position, world_rotation.
// - UI: anchored_position, size_delta, ui_tint, ui_alpha.
// - Camera and lights: camera_fov, light_intensity, light_color.
// - Any component field: field. It reads the field through a proc that finds
//   the component each tick, so a component that goes away ends the tween and
//   nothing points at freed memory. The plugins that own other components
//   build their tweens on it (plugins/sprites/tween, plugins/audio/tween).
//
// Every tween here but `field` is also a node type, so a tree authors it:
// the world and UI layout moves, the tint, the camera and light fields, and
// TweenEvent, which calls into code by name. `field` holds a proc, so it is
// made from code.

import "base:runtime"
import "core:math/linalg"
import engine "moonhug:packages/engine"

// --- World space -----------------------------------------------------------------------

@(typ_guid={guid="b70c29d6-bb2e-4364-b402-9e1b2a09de57"})
TweenMoveToWorld :: struct {
    using base : Tween `inline:""`,
    using anim : Tween_Anim `inline:""`,
    position : [3]f32,
    duration : f32,
    // Above 0: units per second, and the duration follows from the distance.
    speed    : f32 `decor:min(0)`,

    from     : [3]f32 `json:"-"`,
}

type_cleanup_TweenMoveToWorld :: proc(self: ^TweenMoveToWorld) {
    type_cleanup_Tween_Anim(&self.anim)
    self^ = {}
}

begin_TweenMoveToWorld :: proc(self: ^TweenMoveToWorld, ctx: TweenContext) -> bool {
    target := subject_of(&self.base, ctx)
    if !engine.pool_valid(&engine.ctx_world().transforms, engine.Handle(target)) do return false
    self.from = engine.transform_world_position(target)
    if self.speed > 0 do self.duration = linalg.length(self.position - self.from) / self.speed
    return true
}

apply_TweenMoveToWorld :: proc(self: ^TweenMoveToWorld, t: f32, ctx: TweenContext) {
    engine.transform_set_world_position(subject_of(&self.base, ctx), self.from + (self.position - self.from) * t)
}

@(typ_guid={guid="09772b39-cce4-40ee-89ca-30387215c74d"})
TweenRotateToWorld :: struct {
    using base : Tween `inline:""`,
    using anim : Tween_Anim `inline:""`,
    rotation : [4]f32 `inspect:"" decor:euler()`,
    duration : f32,

    from     : [4]f32 `json:"-"`,
}

type_cleanup_TweenRotateToWorld :: proc(self: ^TweenRotateToWorld) {
    type_cleanup_Tween_Anim(&self.anim)
    self^ = {}
}

begin_TweenRotateToWorld :: proc(self: ^TweenRotateToWorld, ctx: TweenContext) -> bool {
    target := subject_of(&self.base, ctx)
    if !engine.pool_valid(&engine.ctx_world().transforms, engine.Handle(target)) do return false
    self.from = engine.transform_world_rotation(target)
    return true
}

apply_TweenRotateToWorld :: proc(self: ^TweenRotateToWorld, t: f32, ctx: TweenContext) {
    to := self.rotation if self.rotation != {} else engine.QUAT_IDENTITY
    q := linalg.quaternion_slerp(engine.quat_to_native(self.from), engine.quat_to_native(to), t)
    engine.transform_set_world_rotation(subject_of(&self.base, ctx), engine.quat_from_native(q))
}

// --- UI layout ---------------------------------------------------------------------------

// Moves a RectTransform's anchored position: canvas units from its anchors.
@(typ_guid={guid="479f27f6-c434-4852-9380-1ef1c45a96d3"})
TweenAnchoredPosition :: struct {
    using base : Tween `inline:""`,
    using anim : Tween_Anim `inline:""`,
    position : [3]f32,
    duration : f32,
    // Above 0: canvas units per second, and the duration follows from the distance.
    speed    : f32 `decor:min(0)`,

    from     : [3]f32 `json:"-"`,
}

type_cleanup_TweenAnchoredPosition :: proc(self: ^TweenAnchoredPosition) {
    type_cleanup_Tween_Anim(&self.anim)
    self^ = {}
}

begin_TweenAnchoredPosition :: proc(self: ^TweenAnchoredPosition, ctx: TweenContext) -> bool {
    _, rect := engine.transform_get_comp(subject_of(&self.base, ctx), engine.RectTransform)
    if rect == nil do return false
    self.from = rect.anchored_position
    if self.speed > 0 do self.duration = linalg.length(self.position - self.from) / self.speed
    return true
}

apply_TweenAnchoredPosition :: proc(self: ^TweenAnchoredPosition, t: f32, ctx: TweenContext) {
    _, rect := engine.transform_get_comp(subject_of(&self.base, ctx), engine.RectTransform)
    if rect == nil do return
    rect.anchored_position = self.from + (self.position - self.from) * t
}

// Resizes a RectTransform: its size delta, the size added to its anchor span.
@(typ_guid={guid="2336ee9a-1594-4e89-a8ce-f4175f71b118"})
TweenSizeDelta :: struct {
    using base : Tween `inline:""`,
    using anim : Tween_Anim `inline:""`,
    size     : [2]f32,
    duration : f32,

    from     : [2]f32 `json:"-"`,
}

type_cleanup_TweenSizeDelta :: proc(self: ^TweenSizeDelta) {
    type_cleanup_Tween_Anim(&self.anim)
    self^ = {}
}

begin_TweenSizeDelta :: proc(self: ^TweenSizeDelta, ctx: TweenContext) -> bool {
    _, rect := engine.transform_get_comp(subject_of(&self.base, ctx), engine.RectTransform)
    if rect == nil do return false
    self.from = rect.size_delta
    return true
}

apply_TweenSizeDelta :: proc(self: ^TweenSizeDelta, t: f32, ctx: TweenContext) {
    _, rect := engine.transform_get_comp(subject_of(&self.base, ctx), engine.RectTransform)
    if rect == nil do return
    rect.size_delta = self.from + (self.size - self.from) * t
}

// --- Any component field -----------------------------------------------------------------

// Finds the field on the object: a pointer to its first number, nil when the
// component is not there. It runs every tick, so it does not keep the pointer.
Field_Access :: #type proc(target: engine.Transform_Handle) -> rawptr

// Which of a field's numbers a tween writes.
Field_Mask :: bit_set[0 ..< 4; u8]

// A value node over a component field of up to four f32, reached through a
// Field_Access. Made from code (field).
@(typ_guid={guid="0023b1b7-fcf9-4a05-b639-c264eaa713a8"})
TweenField :: struct {
    using base: Tween `inline:""`,
    using anim: Tween_Anim `inline:""`,
    duration: f32,

    to:     [4]f32 `json:"-" inspect:"-"`,
    from:   [4]f32 `json:"-" inspect:"-"`,
    width:  u8 `json:"-" inspect:"-"`,
    mask:   Field_Mask `json:"-" inspect:"-"`,
    speed:  f32 `json:"-" inspect:"-"`,
    access: Field_Access `json:"-" inspect:"-"`,
}

type_cleanup_TweenField :: proc(self: ^TweenField) {
    type_cleanup_Tween_Anim(&self.anim)
    self^ = {}
}

begin_TweenField :: proc(self: ^TweenField, ctx: TweenContext) -> bool {
    p := cast([^]f32)self.access(subject_of(&self.base, ctx))
    if p == nil do return false
    for i in 0 ..< int(self.width) {
        self.from[i] = p[i]
        // A number the tween does not write stays what it is.
        if i not_in self.mask do self.to[i] = p[i]
    }
    if self.speed > 0 do self.duration = linalg.length(self.to - self.from) / self.speed
    return true
}

apply_TweenField :: proc(self: ^TweenField, t: f32, ctx: TweenContext) {
    p := cast([^]f32)self.access(subject_of(&self.base, ctx))
    if p == nil do return
    for i in 0 ..< int(self.width) {
        if i in self.mask do p[i] = self.from[i] + (self.to[i] - self.from[i]) * t
    }
}

// Animates a component field of the object from what it holds to `to`.
// `access` returns the field's address, or nil when the component is gone,
// which ends the tween. One form per width: a number, or 2, 3 or 4 numbers.
//
//   fov_of :: proc(target: engine.Transform_Handle) -> rawptr {
//       _, camera := engine.transform_get_comp(target, engine.Camera)
//       return &camera.fov if camera != nil else nil
//   }
//   tween.field(camera_object, fov_of, 40, 0.5)
field :: proc {
    field_f32,
    field_vec2,
    field_vec3,
    field_vec4,
}

field_f32 :: proc(target: engine.Transform_Handle, access: Field_Access, to: f32, timing: Timing, ease := Ease.Linear, opt := Options{}) -> Handle {
    return field_masked(target, access, {to, 0, 0, 0}, 1, {0}, timing, ease, opt)
}

field_vec2 :: proc(target: engine.Transform_Handle, access: Field_Access, to: [2]f32, timing: Timing, ease := Ease.Linear, opt := Options{}) -> Handle {
    return field_masked(target, access, {to.x, to.y, 0, 0}, 2, {0, 1}, timing, ease, opt)
}

field_vec3 :: proc(target: engine.Transform_Handle, access: Field_Access, to: [3]f32, timing: Timing, ease := Ease.Linear, opt := Options{}) -> Handle {
    return field_masked(target, access, {to.x, to.y, to.z, 0}, 3, {0, 1, 2}, timing, ease, opt)
}

field_vec4 :: proc(target: engine.Transform_Handle, access: Field_Access, to: [4]f32, timing: Timing, ease := Ease.Linear, opt := Options{}) -> Handle {
    return field_masked(target, access, to, 4, {0, 1, 2, 3}, timing, ease, opt)
}

// field for part of a field: `width` numbers are read, the ones in `mask`
// are written. A color's alpha alone is width 4, mask {3}.
field_masked :: proc(target: engine.Transform_Handle, access: Field_Access, to: [4]f32, width: u8, mask: Field_Mask, timing: Timing, ease := Ease.Linear, opt := Options{}) -> Handle {
    d, e, o := timing_resolve(timing, ease, opt)
    assert(access != nil, "tween.field: needs a proc that finds the field")
    assert(width >= 1 && width <= 4, "tween.field: a field is 1 to 4 numbers")
    h, node := node_new(TweenField)
    node.to = to
    node.width = width
    node.mask = mask
    node.access = access
    node.duration = d
    node.speed = o.speed
    return start_value_node(h, &node.base, &node.anim, target, e, o)
}

// --- Authored field tweens ----------------------------------------------------------------
//
// The same fields ui_tint, camera_fov, light_intensity and light_color reach
// from code, as node types a tree authors.

@(private = "file")
_field_begin :: proc(p: rawptr, from: []f32) -> bool {
    if p == nil do return false
    for i in 0 ..< len(from) do from[i] = (cast([^]f32)p)[i]
    return true
}

// Tints a UI graphic: the runtime color its CanvasRenderer multiplies the
// graphic's own color with. `alpha_only` fades it and leaves the color.
@(typ_guid={guid="8ca73f00-13f9-4d42-a2d9-432e52f1625b"})
TweenUITint :: struct {
    using base : Tween `inline:""`,
    using anim : Tween_Anim `inline:""`,
    tint       : [4]f32 `decor:color()`,
    alpha_only : bool,
    duration   : f32,

    from       : [4]f32 `json:"-"`,
}

type_reset_TweenUITint :: proc(self: ^TweenUITint) {
    self.tint = {1, 1, 1, 1}
}

type_cleanup_TweenUITint :: proc(self: ^TweenUITint) {
    type_cleanup_Tween_Anim(&self.anim)
    self^ = {}
}

begin_TweenUITint :: proc(self: ^TweenUITint, ctx: TweenContext) -> bool {
    return _field_begin(_tint_of(subject_of(&self.base, ctx)), self.from[:])
}

apply_TweenUITint :: proc(self: ^TweenUITint, t: f32, ctx: TweenContext) {
    p := cast(^[4]f32)_tint_of(subject_of(&self.base, ctx))
    if p == nil do return
    v := self.from + (self.tint - self.from) * t
    if self.alpha_only do p.a = v.a
    else do p^ = v
}

@(typ_guid={guid="51493940-83f6-4bd0-9fc0-1b2fd0f6891d"})
TweenCameraFov :: struct {
    using base : Tween `inline:""`,
    using anim : Tween_Anim `inline:""`,
    fov      : f32 `decor:range(1, 179)`,
    duration : f32,

    from     : f32 `json:"-"`,
}

type_reset_TweenCameraFov :: proc(self: ^TweenCameraFov) {
    self.fov = 60
}

type_cleanup_TweenCameraFov :: proc(self: ^TweenCameraFov) {
    type_cleanup_Tween_Anim(&self.anim)
    self^ = {}
}

begin_TweenCameraFov :: proc(self: ^TweenCameraFov, ctx: TweenContext) -> bool {
    from: [1]f32
    ok := _field_begin(_camera_fov_of(subject_of(&self.base, ctx)), from[:])
    self.from = from[0]
    return ok
}

apply_TweenCameraFov :: proc(self: ^TweenCameraFov, t: f32, ctx: TweenContext) {
    p := cast(^f32)_camera_fov_of(subject_of(&self.base, ctx))
    if p != nil do p^ = self.from + (self.fov - self.from) * t
}

@(typ_guid={guid="156cabca-8ea7-43d9-9b2d-340ccc1076bd"})
TweenLightIntensity :: struct {
    using base : Tween `inline:""`,
    using anim : Tween_Anim `inline:""`,
    intensity : f32 `decor:min(0)`,
    duration  : f32,

    from      : f32 `json:"-"`,
}

type_reset_TweenLightIntensity :: proc(self: ^TweenLightIntensity) {
    self.intensity = 1
}

type_cleanup_TweenLightIntensity :: proc(self: ^TweenLightIntensity) {
    type_cleanup_Tween_Anim(&self.anim)
    self^ = {}
}

begin_TweenLightIntensity :: proc(self: ^TweenLightIntensity, ctx: TweenContext) -> bool {
    from: [1]f32
    ok := _field_begin(_light_intensity_of(subject_of(&self.base, ctx)), from[:])
    self.from = from[0]
    return ok
}

apply_TweenLightIntensity :: proc(self: ^TweenLightIntensity, t: f32, ctx: TweenContext) {
    p := cast(^f32)_light_intensity_of(subject_of(&self.base, ctx))
    if p != nil do p^ = self.from + (self.intensity - self.from) * t
}

// A light's color. Its alpha is unused.
@(typ_guid={guid="1397b975-3c30-457e-afa9-cb4ca231c114"})
TweenLightColor :: struct {
    using base : Tween `inline:""`,
    using anim : Tween_Anim `inline:""`,
    color    : [4]f32 `decor:color()`,
    duration : f32,

    from     : [3]f32 `json:"-"`,
}

type_reset_TweenLightColor :: proc(self: ^TweenLightColor) {
    self.color = {1, 1, 1, 1}
}

type_cleanup_TweenLightColor :: proc(self: ^TweenLightColor) {
    type_cleanup_Tween_Anim(&self.anim)
    self^ = {}
}

begin_TweenLightColor :: proc(self: ^TweenLightColor, ctx: TweenContext) -> bool {
    return _field_begin(_light_color_of(subject_of(&self.base, ctx)), self.from[:])
}

apply_TweenLightColor :: proc(self: ^TweenLightColor, t: f32, ctx: TweenContext) {
    p := cast(^[3]f32)_light_color_of(subject_of(&self.base, ctx))
    if p != nil do p^ = self.from + (self.color.rgb - self.from) * t
}

// --- Events ------------------------------------------------------------------------------

// How an authored tree calls into code: when the tree gets here, the run's
// on_event proc is called with `name`. A tree cannot hold a proc, so the code
// that starts the tree says what a name means:
//
//   h := tween.run(&d.tree, tween.TweenContext{subject = d.owner})
//   tween.on_event(h, door_event, d)   // door_event(name, user): "opened", "closed"
@(typ_guid={guid="171f4755-5cb0-4edd-b2fc-c415e7d529ae"})
TweenEvent :: struct {
    using base : Tween `inline:""`,
    name       : string,
}

type_cleanup_TweenEvent :: proc(self: ^TweenEvent) {
    delete(self.name)
    self^ = {}
}

tick_TweenEvent :: proc(self: ^TweenEvent, dt: f32, ctx: TweenContext) -> Status {
    if has_delay(&self.base, dt) do return .Running
    event_emit(ctx.run, self.name)
    return .Done
}

// --- Code API over the nodes above -------------------------------------------------------

// Moves the object's world position from where it is to `to`.
world_position :: proc(target: engine.Transform_Handle, to: [3]f32, timing: Timing, ease := Ease.Linear, opt := Options{}) -> Handle {
    d, e, o := timing_resolve(timing, ease, opt)
    h, node := node_new(TweenMoveToWorld)
    node.position = to
    node.duration = d
    node.speed = o.speed
    return start_value_node(h, &node.base, &node.anim, target, e, o)
}

// Rotates the object from its world rotation to the quaternion `to`.
world_rotation :: proc(target: engine.Transform_Handle, to: [4]f32, timing: Timing, ease := Ease.Linear, opt := Options{}) -> Handle {
    d, e, o := timing_resolve(timing, ease, opt)
    assert(opt.speed == 0, "tween.world_rotation: no speed option, give a duration")
    h, node := node_new(TweenRotateToWorld)
    node.rotation = to
    node.duration = d
    return start_value_node(h, &node.base, &node.anim, target, e, o)
}

// Moves a UI object's anchored position: canvas units from its anchors.
anchored_position :: proc(target: engine.Transform_Handle, to: [3]f32, timing: Timing, ease := Ease.Linear, opt := Options{}) -> Handle {
    d, e, o := timing_resolve(timing, ease, opt)
    h, node := node_new(TweenAnchoredPosition)
    node.position = to
    node.duration = d
    node.speed = o.speed
    return start_value_node(h, &node.base, &node.anim, target, e, o)
}

// Resizes a UI object: its size delta, the size added to its anchor span.
size_delta :: proc(target: engine.Transform_Handle, to: [2]f32, timing: Timing, ease := Ease.Linear, opt := Options{}) -> Handle {
    d, e, o := timing_resolve(timing, ease, opt)
    assert(opt.speed == 0, "tween.size_delta: no speed option, give a duration")
    h, node := node_new(TweenSizeDelta)
    node.size = to
    node.duration = d
    return start_value_node(h, &node.base, &node.anim, target, e, o)
}

// Tints a UI graphic: the runtime color its CanvasRenderer multiplies the
// graphic's own color with. It is not saved. An untinted graphic starts white.
ui_tint :: proc(target: engine.Transform_Handle, to: [4]f32, timing: Timing, ease := Ease.Linear, opt := Options{}) -> Handle {
    return field(target, _tint_of, to, timing, ease, opt)
}

// Fades a UI graphic: the alpha of its tint, the color staying what it is.
ui_alpha :: proc(target: engine.Transform_Handle, to: f32, timing: Timing, ease := Ease.Linear, opt := Options{}) -> Handle {
    return field_masked(target, _tint_of, {0, 0, 0, to}, 4, {3}, timing, ease, opt)
}

// A camera's vertical field of view in degrees.
camera_fov :: proc(target: engine.Transform_Handle, to: f32, timing: Timing, ease := Ease.Linear, opt := Options{}) -> Handle {
    return field(target, _camera_fov_of, to, timing, ease, opt)
}

light_intensity :: proc(target: engine.Transform_Handle, to: f32, timing: Timing, ease := Ease.Linear, opt := Options{}) -> Handle {
    return field(target, _light_intensity_of, to, timing, ease, opt)
}

// A light's color. Its alpha is unused, so three numbers.
light_color :: proc(target: engine.Transform_Handle, to: [3]f32, timing: Timing, ease := Ease.Linear, opt := Options{}) -> Handle {
    return field(target, _light_color_of, to, timing, ease, opt)
}

@(private = "file")
_tint_of :: proc(target: engine.Transform_Handle) -> rawptr {
    _, cr := engine.transform_get_comp(target, engine.CanvasRenderer)
    if cr == nil do return nil
    if !cr.tinted do engine.canvas_renderer_set_tint(cr, {1, 1, 1, 1})
    return &cr.tint
}

@(private = "file")
_camera_fov_of :: proc(target: engine.Transform_Handle) -> rawptr {
    _, camera := engine.transform_get_comp(target, engine.Camera)
    return &camera.fov if camera != nil else nil
}

@(private = "file")
_light_intensity_of :: proc(target: engine.Transform_Handle) -> rawptr {
    _, light := engine.transform_get_comp(target, engine.Light)
    return &light.intensity if light != nil else nil
}

@(private = "file")
_light_color_of :: proc(target: engine.Transform_Handle) -> rawptr {
    _, light := engine.transform_get_comp(target, engine.Light)
    return &light.color if light != nil else nil
}

// Called from register_builtin_nodes.
register_target_nodes :: proc() {
    register_tween(TweenMoveToWorld, begin_TweenMoveToWorld, apply_TweenMoveToWorld)
    register_tween(TweenRotateToWorld, begin_TweenRotateToWorld, apply_TweenRotateToWorld)
    register_tween(TweenAnchoredPosition, begin_TweenAnchoredPosition, apply_TweenAnchoredPosition)
    register_tween(TweenSizeDelta, begin_TweenSizeDelta, apply_TweenSizeDelta)
    register_tween(TweenField, begin_TweenField, apply_TweenField, code_only = true)
    register_tween(TweenShake, begin_TweenShake, apply_TweenShake)
    register_tween(TweenUITint, begin_TweenUITint, apply_TweenUITint)
    register_tween(TweenCameraFov, begin_TweenCameraFov, apply_TweenCameraFov)
    register_tween(TweenLightIntensity, begin_TweenLightIntensity, apply_TweenLightIntensity)
    register_tween(TweenLightColor, begin_TweenLightColor, apply_TweenLightColor)
    register_node(TweenEvent, tick_TweenEvent, .Instant)
}

// Fills what every value node shares from the code API's arguments and starts
// the run. A plugin's own one-line tween ends with this, after node_new.
start_value_node :: proc(h: Node_Handle, base: ^Tween, anim: ^Tween_Anim, target: engine.Transform_Handle, ease: Ease, opt: Options) -> Handle {
    base.target = target
    base.delay = opt.delay
    anim.ease = ease
    anim.cycles = opt.cycles
    anim.cycle_mode = opt.cycle_mode
    if opt.curve != nil {
        anim.ease = .Curve
        anim.curve.keys = make([dynamic]engine.Curve_Key, len(opt.curve.keys), runtime.default_allocator())
        copy(anim.curve.keys[:], opt.curve.keys[:])
    }
    return run_node(h, TweenContext{subject = target}, opt.clock)
}
