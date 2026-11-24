package physics2d_sample

// The scripts of the machine scene (assets/physics2d_sample.scene): a marble
// goes around a chain of stations, and each station is one object with its
// own script.
//
// - A sensor turns a MachineSwitch on: MachineTrigger (a trigger collider),
//   MachineEye (a ray) and MachineBell (a hit).
// - An actor reads the MachineSwitch on its own object: MachineMotor,
//   MachineCannon, MachineWalker, MachineElevator and MachineFan.
// - MachineRope only draws: a line from a hook to the body a joint holds.
// - The elevator ends a lap. `machine_lap` goes up by one, and every script
//   puts its object back to how the scene starts: MachineReset does it for a
//   plain rigidbody.

import "core:math"
import b2 "vendor:box2d"
import "moonhug:packages/engine"
import physics2d "moonhug:packages/physics2d"
import sprites "moonhug:packages/sprites"

// The lap the machine is on. A script that sees a new value resets itself.
machine_lap: int

// The angle around Z of a world rotation, in radians.
@(private = "file")
_z_angle :: proc(rotation: [4]f32) -> f32 {
	return 2 * math.atan2(rotation.z, rotation.w)
}

@(private = "file")
_is_marble :: proc(tH: engine.Transform_Handle) -> bool {
	_, m := engine.transform_get_comp(tH, MachineMarble)
	return m != nil
}

// The body of `tH` when it is a dynamic one.
@(private = "file")
_dynamic_body :: proc(tH: engine.Transform_Handle) -> (b2.BodyId, bool) {
	body, ok := physics2d.body_of(tH)
	if !ok || b2.Body_GetType(body) != .dynamicBody do return {}, false
	return body, true
}

// --- The marble ----------------------------------------------------------------

// Marks the marble: the sensors react to it and to nothing else.
@(component={menu="Demo/MachineMarble"})
@(typ_guid={guid = "5f0c7c2e-3b0f-4a52-9d53-2d4f1c1a7e01"})
MachineMarble :: struct {
	using base: engine.CompData `inspect:"-"`,
}

// --- The switch ----------------------------------------------------------------

// On or off. Sensors turn it on, the actor on the same object reads it, and
// the sprite on the same object shows it.
@(component={menu="Demo/MachineSwitch"})
@(typ_guid={guid = "5f0c7c2e-3b0f-4a52-9d53-2d4f1c1a7e02"})
MachineSwitch :: struct {
	using base: engine.CompData `inspect:"-"`,
	on:         bool,
	// Seconds between a sensor's signal and the switch going on.
	delay:      f32 `decor:min(0)`,
	// The sprite's color while on. Alpha 0 leaves the sprite alone.
	on_color:   [4]f32 `decor:color()`,

	wait:      f32 `json:"-" inspect:"-"`,
	start_on:  bool `json:"-" inspect:"-"`,
	off_color: [4]f32 `json:"-" inspect:"-"`,
	started:   bool `json:"-" inspect:"-"`,
	lap:       int `json:"-" inspect:"-"`,
}

// Turns a switch on, after its delay. A switch that is on or waiting stays so.
machine_switch_on :: proc(target: engine.Ref_Local) {
	s := cast(^MachineSwitch)engine.world_pool_get(engine.ctx_world(), target.handle)
	if s == nil || s.on || s.wait > 0 do return
	s.wait = max(s.delay, 0.0001)
}

// Before the actors, so an actor sees the switch of this tick.
@(comp_fixed_update={order=-10, component=MachineSwitch})
comp_fixed_update_MachineSwitch :: proc(dt: f32, s: ^MachineSwitch) {
	_, sprite := engine.transform_get_comp(s.owner, sprites.SpriteRenderer)
	if !s.started {
		s.started = true
		s.lap = machine_lap
		s.start_on = s.on
		if sprite != nil do s.off_color = sprite.color
	}
	if s.lap != machine_lap {
		s.lap = machine_lap
		s.on = s.start_on
		s.wait = 0
	}
	if s.wait > 0 {
		s.wait -= dt
		if s.wait <= 0 do s.on = true
	}
	if sprite != nil && s.on_color.a > 0 do sprite.color = s.on_color if s.on else s.off_color
}

// --- Sensors -------------------------------------------------------------------

// On a trigger collider: the marble entering it turns the target switch on.
@(component={menu="Demo/MachineTrigger"})
@(typ_guid={guid = "5f0c7c2e-3b0f-4a52-9d53-2d4f1c1a7e03"})
MachineTrigger :: struct {
	using base: engine.CompData `inspect:"-"`,
	target:     engine.Ref_Local `ref:"MachineSwitch"`,
}

@(comp_on_trigger_enter={component=MachineTrigger})
comp_on_trigger_enter_MachineTrigger :: proc(c: ^MachineTrigger, other: engine.Transform_Handle) {
	if c.enabled && _is_marble(other) do machine_switch_on(c.target)
}

// On a collider: anything hitting it turns the target switch on, and the
// sprite flashes.
@(component={menu="Demo/MachineBell"})
@(typ_guid={guid = "5f0c7c2e-3b0f-4a52-9d53-2d4f1c1a7e04"})
MachineBell :: struct {
	using base: engine.CompData `inspect:"-"`,
	target:     engine.Ref_Local `ref:"MachineSwitch"`,
	ring_color: [4]f32 `decor:color()`,

	ring:       f32 `json:"-" inspect:"-"`,
	rest_color: [4]f32 `json:"-" inspect:"-"`,
	started:    bool `json:"-" inspect:"-"`,
}

@(comp_on_collision_enter={component=MachineBell})
comp_on_collision_enter_MachineBell :: proc(c: ^MachineBell, other: engine.Transform_Handle) {
	if !c.enabled do return
	c.ring = 1
	machine_switch_on(c.target)
}

@(comp_fixed_update={component=MachineBell})
comp_fixed_update_MachineBell :: proc(dt: f32, c: ^MachineBell) {
	_, sprite := engine.transform_get_comp(c.owner, sprites.SpriteRenderer)
	if sprite == nil do return
	if !c.started {
		c.started = true
		c.rest_color = sprite.color
	}
	c.ring = max(c.ring - dt * 2, 0)
	sprite.color = c.rest_color + (c.ring_color - c.rest_color) * c.ring
}

// A ray along the object's own X axis: the marble crossing it turns the
// target switch on. `beam` is stretched from the eye to what the ray hits.
@(component={menu="Demo/MachineEye"})
@(typ_guid={guid = "5f0c7c2e-3b0f-4a52-9d53-2d4f1c1a7e05"})
MachineEye :: struct {
	using base: engine.CompData `inspect:"-"`,
	target:     engine.Ref_Local `ref:"MachineSwitch"`,
	range:      f32 `decor:min(0)`,
	// A child with a sprite one unit long.
	beam:       engine.Ref_Local `ref:"Transform"`,
}

type_reset_MachineEye :: proc(c: ^MachineEye) {
	engine.comp_zero(c)
	c.range = 2
}

@(comp_fixed_update={component=MachineEye})
comp_fixed_update_MachineEye :: proc(dt: f32, c: ^MachineEye) {
	tw := engine.transform_world(c.owner)
	angle := _z_angle(tw.rotation)
	length := c.range
	if hit, ok := physics2d.raycast(tw.position.xy, {math.cos(angle), math.sin(angle)}, c.range, ignore = c.owner); ok {
		length = hit.distance
		if _is_marble(hit.object) do machine_switch_on(c.target)
	}
	if beam := engine.pool_get(&engine.ctx_world().transforms, c.beam.handle); beam != nil {
		beam.position.x = length * 0.5
		beam.scale.x = length
	}
}

// --- Actors --------------------------------------------------------------------

// Drives the HingeJoint2D on its object: one motor speed while the switch
// is on, another while it is off.
@(component={menu="Demo/MachineMotor"})
@(typ_guid={guid = "5f0c7c2e-3b0f-4a52-9d53-2d4f1c1a7e06"})
MachineMotor :: struct {
	using base: engine.CompData `inspect:"-"`,
	// Degrees per second, counterclockwise.
	on_speed:   f32,
	off_speed:  f32,
}

@(comp_fixed_update={component=MachineMotor})
comp_fixed_update_MachineMotor :: proc(dt: f32, c: ^MachineMotor) {
	_, hinge := engine.transform_get_comp(c.owner, physics2d.HingeJoint2D)
	_, s := engine.transform_get_comp(c.owner, MachineSwitch)
	if hinge == nil || s == nil do return
	hinge.use_motor = true
	hinge.motor_speed = c.on_speed if s.on else c.off_speed
}

// Fires `shell` along the object's own X axis when the switch goes on.
@(component={menu="Demo/MachineCannon"})
@(typ_guid={guid = "5f0c7c2e-3b0f-4a52-9d53-2d4f1c1a7e07"})
MachineCannon :: struct {
	using base: engine.CompData `inspect:"-"`,
	shell:      engine.Ref_Local `ref:"Rigidbody2D"`,
	// Meters per second.
	speed:      f32 `decor:min(0)`,

	fired: bool `json:"-" inspect:"-"`,
}

type_reset_MachineCannon :: proc(c: ^MachineCannon) {
	engine.comp_zero(c)
	c.speed = 20
}

@(comp_fixed_update={component=MachineCannon})
comp_fixed_update_MachineCannon :: proc(dt: f32, c: ^MachineCannon) {
	_, s := engine.transform_get_comp(c.owner, MachineSwitch)
	if s == nil do return
	if !s.on {
		c.fired = false
		return
	}
	if c.fired do return
	c.fired = true
	body, ok := _dynamic_body(physics2d.joint_connected_object(c.shell))
	if !ok do return
	angle := _z_angle(engine.transform_world(c.owner).rotation)
	b2.Body_SetLinearVelocity(body, [2]f32{math.cos(angle), math.sin(angle)} * c.speed)
	b2.Body_SetAwake(body, true)
}

// Pushes every dynamic body inside a box, each fixed step. It blows for
// `blow` seconds, rests for `rest` seconds, and so on. With a MachineSwitch
// on the object, only while that is on.
@(component={menu="Demo/MachineFan"})
@(typ_guid={guid = "5f0c7c2e-3b0f-4a52-9d53-2d4f1c1a7e08"})
MachineFan :: struct {
	using base: engine.CompData `inspect:"-"`,
	// The box, from the object's position, in world axes.
	offset:     [2]f32,
	size:       [2]f32,
	// Newtons on each body.
	force:      [2]f32,
	blow:       f32 `decor:min(0)`,
	rest:       f32 `decor:min(0)`,

	clock: f32 `json:"-" inspect:"-"`,
}

type_reset_MachineFan :: proc(c: ^MachineFan) {
	engine.comp_zero(c)
	c.size = {1, 2}
	c.offset = {0, 1}
	c.force = {0, 2}
	c.blow = 2
}

@(comp_fixed_update={component=MachineFan})
comp_fixed_update_MachineFan :: proc(dt: f32, c: ^MachineFan) {
	if _, s := engine.transform_get_comp(c.owner, MachineSwitch); s != nil && !s.on do return
	c.clock += dt
	if c.clock >= c.blow + c.rest do c.clock = 0
	blowing := c.clock < c.blow
	if _, sprite := engine.transform_get_comp(c.owner, sprites.SpriteRenderer); sprite != nil do sprite.color.a = 1 if blowing else 0.35
	if !blowing do return
	center := engine.transform_world(c.owner).position.xy + c.offset
	for tH in physics2d.overlap_box(center, c.size * 0.5, ignore = c.owner) {
		if body, ok := _dynamic_body(tH); ok do b2.Body_ApplyForceToCenter(body, c.force, true)
	}
}

// A CharacterController2D that walks out when its switch goes on, kicks
// the marble it meets, turns at a wall or at the end of its beat, and walks
// home.
@(component={menu="Demo/MachineWalker"})
@(typ_guid={guid = "5f0c7c2e-3b0f-4a52-9d53-2d4f1c1a7e09"})
MachineWalker :: struct {
	using base: engine.CompData `inspect:"-"`,
	// Meters per second. Negative walks out to the left.
	speed:      f32,
	// How far it walks out.
	beat:       f32 `decor:min(0)`,
	// The velocity the marble gets: x along the way out, y up.
	kick:       [2]f32,

	phase:   Walker_Phase `json:"-" inspect:"-"`,
	start:   [3]f32 `json:"-" inspect:"-"`,
	fall:    f32 `json:"-" inspect:"-"`,
	started: bool `json:"-" inspect:"-"`,
	lap:     int `json:"-" inspect:"-"`,
}

Walker_Phase :: enum u8 {
	Home,
	Out,
	Back,
}

type_reset_MachineWalker :: proc(c: ^MachineWalker) {
	engine.comp_zero(c)
	c.speed = -2
	c.beat = 4
	c.kick = {3, 6}
}

@(comp_fixed_update={component=MachineWalker})
comp_fixed_update_MachineWalker :: proc(dt: f32, c: ^MachineWalker) {
	_, cc := engine.transform_get_comp(c.owner, physics2d.CharacterController2D)
	_, s := engine.transform_get_comp(c.owner, MachineSwitch)
	if cc == nil || s == nil do return
	pos := engine.transform_world(c.owner).position
	if !c.started {
		c.started = true
		c.lap = machine_lap
		c.start = pos
	}
	if c.lap != machine_lap {
		c.lap = machine_lap
		c.phase = .Home
		c.fall = 0
		engine.transform_set_world_position(c.owner, c.start)
		return
	}

	out := math.sign(c.speed)
	step: f32
	switch c.phase {
	case .Home:
		if s.on do c.phase = .Out
	case .Out:
		step = c.speed * dt
		// A circle a little ahead of the capsule: what it is about to walk into.
		middle := pos.xy + cc.offset
		if hit, ok := physics2d.circle_cast(middle, cc.radius * 0.8, {out, 0}, cc.radius * 0.5 + 0.1, ignore = c.owner); ok && _is_marble(hit.object) {
			if body, is_body := _dynamic_body(hit.object); is_body {
				b2.Body_SetLinearVelocity(body, {c.kick.x * out, c.kick.y})
				b2.Body_SetAwake(body, true)
			}
			c.phase = .Back
		}
		if abs(pos.x - c.start.x) >= c.beat || .Sides in cc.collision_flags do c.phase = .Back
	case .Back:
		step = -c.speed * dt
		if (pos.x - c.start.x) * out <= 0 {
			step = 0
			c.phase = .Home
			s.on = false
		}
	}
	c.fall = 0 if cc.is_grounded else c.fall - 20 * dt
	physics2d.character_move(cc, {step, c.fall * dt - 0.01})
}

// A kinematic car. When its switch goes on it rises, tips over to roll
// the marble out, starts the next lap, and comes back down.
@(component={menu="Demo/MachineElevator"})
@(typ_guid={guid = "5f0c7c2e-3b0f-4a52-9d53-2d4f1c1a7e0a"})
MachineElevator :: struct {
	using base: engine.CompData `inspect:"-"`,
	// How far up it goes, and how fast, in meters and meters per second.
	rise:       f32 `decor:min(0)`,
	speed:      f32 `decor:min(0)`,
	// The angle it tips to at the top, in degrees. It rests at the angle
	// the scene gives it.
	tip:        f32,
	// Seconds it stays tipped.
	hold:       f32 `decor:min(0)`,

	phase:   Elevator_Phase `json:"-" inspect:"-"`,
	start:   [3]f32 `json:"-" inspect:"-"`,
	rest:    f32 `json:"-" inspect:"-"`, // degrees
	angle:   f32 `json:"-" inspect:"-"`,
	timer:   f32 `json:"-" inspect:"-"`,
	started: bool `json:"-" inspect:"-"`,
}

Elevator_Phase :: enum u8 {
	Down,
	Rise,
	Tip,
	Hold,
	Untip,
	Descend,
}

type_reset_MachineElevator :: proc(c: ^MachineElevator) {
	engine.comp_zero(c)
	c.rise = 5
	c.speed = 2
	c.tip = -15
	c.hold = 1.5
}

// How fast the car tips, in degrees per second.
@(private = "file")
_TIP_SPEED :: f32(40)

@(comp_fixed_update={component=MachineElevator})
comp_fixed_update_MachineElevator :: proc(dt: f32, c: ^MachineElevator) {
	_, s := engine.transform_get_comp(c.owner, MachineSwitch)
	if s == nil do return
	tw := engine.transform_world(c.owner)
	if !c.started {
		c.started = true
		c.start = tw.position
		c.rest = math.to_degrees(_z_angle(tw.rotation))
		c.angle = c.rest
	}
	pos := tw.position
	toward :: proc(value, target, step: f32) -> f32 {
		return min(value + step, target) if value < target else max(value - step, target)
	}
	switch c.phase {
	case .Down:
		if s.on do c.phase = .Rise
	case .Rise:
		pos.y = min(pos.y + c.speed * dt, c.start.y + c.rise)
		if pos.y >= c.start.y + c.rise do c.phase = .Tip
	case .Tip:
		c.angle = toward(c.angle, c.tip, _TIP_SPEED * dt)
		if c.angle == c.tip {
			c.phase = .Hold
			c.timer = c.hold
			// The marble is on its way out: everything else goes back to its start.
			machine_lap += 1
		}
	case .Hold:
		c.timer -= dt
		if c.timer <= 0 do c.phase = .Untip
	case .Untip:
		c.angle = toward(c.angle, c.rest, _TIP_SPEED * dt)
		if c.angle == c.rest do c.phase = .Descend
	case .Descend:
		pos.y = max(pos.y - c.speed * dt, c.start.y)
		if pos.y <= c.start.y do c.phase = .Down
	}
	engine.transform_set_world_position(c.owner, pos)
	engine.transform_set_world_rotation(c.owner, engine.quat_from_euler_xyz(0, 0, c.angle))
}

// --- Looks ---------------------------------------------------------------------

// Shows a rope or a spring: stretches its object, a sprite one unit long,
// from a point in the world to an anchor on another object.
@(component={menu="Demo/MachineRope"})
@(typ_guid={guid = "5f0c7c2e-3b0f-4a52-9d53-2d4f1c1a7e0c"})
MachineRope :: struct {
	using base: engine.CompData `inspect:"-"`,
	from:       [2]f32,
	to:         engine.Ref_Local `ref:"Transform"`,
	// In the other object's own space.
	to_anchor:  [2]f32,
}

// After the physics step has written the bodies back to their objects.
@(comp_fixed_update={order=1100, component=MachineRope})
comp_fixed_update_MachineRope :: proc(dt: f32, c: ^MachineRope) {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(c.owner))
	if t == nil || !engine.pool_valid(&w.transforms, c.to.handle) do return
	end := physics2d.joint_anchor_world(engine.Transform_Handle(c.to.handle), c.to_anchor)
	along := end - c.from
	middle := (c.from + end) * 0.5
	engine.transform_set_world_position(c.owner, {middle.x, middle.y, 0})
	engine.transform_set_world_rotation(c.owner, engine.quat_from_euler_xyz(0, 0, math.to_degrees(math.atan2(along.y, along.x))))
	t.scale.x = math.sqrt(along.x * along.x + along.y * along.y)
}

// --- Reset ---------------------------------------------------------------------

// Puts a dynamic body back where the scene has it when a new lap starts, at
// rest, and builds its broken joints again.
@(component={menu="Demo/MachineReset"})
@(typ_guid={guid = "5f0c7c2e-3b0f-4a52-9d53-2d4f1c1a7e0b"})
MachineReset :: struct {
	using base: engine.CompData `inspect:"-"`,

	position: [2]f32 `json:"-" inspect:"-"`,
	rotation: b2.Rot `json:"-" inspect:"-"`,
	started:  bool `json:"-" inspect:"-"`,
	lap:      int `json:"-" inspect:"-"`,
	// Fixed steps until the joints are enabled again: a joint is built from
	// the pose its bodies have then, so the bodies go home first.
	rejoin:   int `json:"-" inspect:"-"`,
}

@(comp_fixed_update={component=MachineReset})
comp_fixed_update_MachineReset :: proc(dt: f32, c: ^MachineReset) {
	body, ok := _dynamic_body(c.owner)
	if !ok do return
	if !c.started {
		c.started = true
		c.lap = machine_lap
		c.position = b2.Body_GetPosition(body)
		c.rotation = b2.Body_GetRotation(body)
	}
	if c.lap != machine_lap {
		c.lap = machine_lap
		b2.Body_SetTransform(body, c.position, c.rotation)
		b2.Body_SetLinearVelocity(body, {})
		b2.Body_SetAngularVelocity(body, 0)
		b2.Body_SetAwake(body, true)
		c.rejoin = 2
	}
	if c.rejoin > 0 {
		c.rejoin -= 1
		if c.rejoin == 0 {
			if _, j := engine.transform_get_comp(c.owner, physics2d.HingeJoint2D); j != nil do j.enabled = true
			if _, j := engine.transform_get_comp(c.owner, physics2d.DistanceJoint2D); j != nil do j.enabled = true
			if _, j := engine.transform_get_comp(c.owner, physics2d.FixedJoint2D); j != nil do j.enabled = true
		}
	}
}
