package particles

// Unity's ParticleSystem, range-based: every "random between two constants"
// start value is a min/max (or color a/b) pair, over-lifetime modules are
// engine.Curve / engine.Gradient. Simulation runs on the CPU per frame
// (@(update) in particles.odin), rendering goes through the renderer seam as
// billboarded Draw_Quad commands. docs/ParticleSystem.md describes the modules.
//
// Serialized fields are ZERO-NEUTRAL: a scene saved before a field existed
// loads it as zero, so zero must mean "off" or "no change" for every field
// (simulation_speed is the one exception — zero falls back to 1).

import "core:math/rand"
import "moonhug:engine"

// One live particle. Positions are in the system's simulation space,
// rotation is the billboard roll in radians.
Particle :: struct {
	position:         [3]f32,
	velocity:         [3]f32,
	color:            [4]f32,
	size:             f32,
	rotation:         f32, // radians
	angular_velocity: f32, // radians per second
	life:             f32, // seconds lived
	lifetime:         f32,
}

// Emission volume, oriented along local +Z (Unity's shape axis).
// New shapes append at the end — the value is the serialized identity.
Emit_Shape :: enum u8 {
	Cone,       // Unity's default: base disc of `shape_radius`, spread `shape_angle`
	Sphere,     // outward from a random point inside `shape_radius`
	Point,      // straight +Z
	Hemisphere, // sphere half on the +Z side
	Circle,     // disc in the XY plane, particles move radially outward
	Edge,       // line along local X of half-length `shape_radius`, particles move +Z
	Box,        // volume of size `shape_box`, particles move +Z
}

Sim_Space :: enum u8 {
	Local, // particles follow the emitter (Unity's default)
	World, // particles are left behind in the world
}

Render_Mode :: enum u8 {
	Billboard, // camera-facing quad
	Stretched, // quad aligned to the particle's velocity
}

Sub_Emitter_Trigger :: enum u8 {
	Birth, // fires when a particle spawns
	Death, // fires when a particle dies
}

// One sub-emitter entry: when a particle hits the trigger, the target
// ParticleSystem fires its authored BURSTS once at the particle's position
// (`probability` gates each trigger, 1 = always). The target authors its
// per-trigger emission as bursts. No heap fields.
Sub_Emitter :: struct {
	target:      engine.Ref_Local `ref:"ParticleSystem"`,
	trigger:     Sub_Emitter_Trigger,
	probability: f32,
}

// One emission burst: `count_min..count_max` particles at `time` seconds into
// the cycle, repeated `cycles` times every `interval` seconds, each cycle
// firing with `probability` (1 = always). Plain data — no heap fields.
Burst :: struct {
	time:        f32,
	count_min:   i32,
	count_max:   i32,
	cycles:      i32, // < 1 plays once
	interval:    f32,
	probability: f32,
}

@(component)
@(typ_guid={guid = "e5a7c2d1-4b3f-4c89-9a16-7d02e8b5f4a3"})
ParticleSystem :: struct {
	using base: engine.CompData `inspect:"-"`,

	// Main
	duration:     f32, // emission window in seconds (looping restarts it)
	looping:      bool,
	prewarm:      bool, // looping systems start as if one cycle already ran
	start_delay:  f32,  // seconds before the first cycle starts
	lifetime_min: f32,
	lifetime_max: f32,
	speed_min:    f32,
	speed_max:    f32,
	size_min:     f32, // world units (Unity's start size)
	size_max:     f32,
	rotation_min: f32, // start rotation, degrees
	rotation_max: f32,
	flip_rotation: f32, // 0..1 fraction of particles spinning the other way
	color_a:      [4]f32 `decor:color()`, // start color: random between a and b
	color_b:      [4]f32 `decor:color()`,
	gravity_modifier: f32,
	sim_space:    Sim_Space,
	simulation_speed: f32, // playback speed scale, 0 runs at 1
	max_particles: i32,
	// 0 draws a fresh seed each reset (Unity's auto random seed); any other
	// value replays the exact same effect — restart-to-time depends on it.
	random_seed: u32,

	// Emission
	rate:               f32, // particles per second
	rate_over_distance: f32, // particles per world unit the emitter moves
	bursts:             [dynamic]Burst,

	// Shape
	shape:        Emit_Shape,
	shape_radius: f32,
	shape_angle:  f32,    // cone spread, degrees from the axis
	shape_box:    [3]f32, // box size (Box shape)
	randomize_direction: f32, // 0..1 blend toward a random direction
	spherize_direction:  f32, // 0..1 blend toward outward-from-center

	// Velocity over lifetime: additive velocity in the emitter's local frame,
	// each axis a curve over life/lifetime evaluated with empty_value 0 —
	// all empty = the module off. Orbital rotates particle positions around
	// the emitter's axes, in degrees per second.
	velocity_x: engine.Curve,
	velocity_y: engine.Curve,
	velocity_z: engine.Curve,
	orbital_x:  engine.Curve,
	orbital_y:  engine.Curve,
	orbital_z:  engine.Curve,

	// Limit velocity over lifetime: speed above `limit_speed` decays toward it
	// by `limit_dampen` (0..1) per frame at 60 Hz. limit_speed 0 = module off.
	limit_speed:  f32,
	limit_dampen: f32,

	// Force over lifetime: acceleration in the emitter's local frame, each
	// axis a curve over life/lifetime evaluated with empty_value 0 — all
	// empty = the module off.
	force_x: engine.Curve,
	force_y: engine.Curve,
	force_z: engine.Curve,

	// Lifetime by emitter speed: multiplies a new particle's lifetime by the
	// curve evaluated at the EMITTER's speed remapped from [min, max] to
	// 0..1. Empty = the module off.
	lifetime_by_speed:     engine.Curve,
	lifetime_by_speed_min: f32,
	lifetime_by_speed_max: f32,

	// By speed: the gradient/curve is evaluated at the particle's speed
	// remapped from [min, max] to 0..1, and multiplies color/size like the
	// over-lifetime modules. Empty = the module off.
	color_by_speed:     engine.Gradient,
	color_by_speed_min: f32,
	color_by_speed_max: f32,
	size_by_speed:      engine.Curve,
	size_by_speed_min:  f32,
	size_by_speed_max:  f32,

	// Rotation over lifetime: angular velocity in degrees per second, random
	// between min and max. Both 0 = module off.
	angular_velocity_min: f32,
	angular_velocity_max: f32,

	// Noise: position jitter from smooth value noise sampled at the
	// particle's position — deterministic, no randomness. strength is world
	// units per second and 0 = the module off, frequency 0 behaves as 1,
	// scroll moves the noise field over time.
	noise_strength:     f32,
	noise_frequency:    f32,
	noise_scroll_speed: f32,

	// Sub emitters: other ParticleSystems triggered by this system's
	// particles. Empty = the module off.
	sub_emitters: [dynamic]Sub_Emitter,

	// Rotation by speed: additional angular velocity (degrees per second)
	// from the curve evaluated at the particle's speed remapped from
	// [min, max] to 0..1. Empty = the module off.
	rotation_by_speed:     engine.Curve,
	rotation_by_speed_min: f32,
	rotation_by_speed_max: f32,

	// Over lifetime, evaluated at life/lifetime: the gradient MULTIPLIES the
	// particle's start color, the curve scales its start size. Empty = the
	// module off (gradient evaluates white, curve evaluates 1).
	color_over_life: engine.Gradient,
	size_over_life:  engine.Curve,

	// Renderer: billboarded quads. The sprite is PPtr{texture guid, slice id}
	// like SpriteRenderer (the editor wrapper draws the picker), material's
	// shader/tint applies with the sprite's own texture.
	sprite:         engine.PPtr `inspect:"-"`,
	material:       engine.Asset_GUID `ext:"mat"`,
	render_mode:    Render_Mode,
	// Stretched quad length = size * length_scale + speed * speed_scale.
	// length_scale 0 behaves as 1 (absent fields load as zero).
	stretch_length_scale: f32,
	stretch_speed_scale:  f32,
	sorting_layer:  i32,
	order_in_layer: i32,

	// Live state — never serialized, never inspected.
	particles: [dynamic]Particle `json:"-" inspect:"-"`,
	time:      f32 `json:"-" inspect:"-"`,
	emit_acc:  f32 `json:"-" inspect:"-"`,
	dist_acc:  f32 `json:"-" inspect:"-"`,
	emitter_speed: f32 `json:"-" inspect:"-"`,
	prev_pos:  [3]f32 `json:"-" inspect:"-"`,
	prev_pos_valid: bool `json:"-" inspect:"-"`,
	prewarmed: bool `json:"-" inspect:"-"`,
	rand_state: rand.Default_Random_State `json:"-" inspect:"-"`,
	seeded:     bool `json:"-" inspect:"-"`,
	// Referenced as a sub-emitter target: the system does not emit on its
	// own timeline, triggers drive it. Recomputed by mark_sub_targets.
	is_sub_target: bool `json:"-" inspect:"-"`,
	// The editor's Self preview scope sets this: the system's own
	// sub-emitters do not fire (their targets are not simulated).
	suppress_sub_emitters: bool `json:"-" inspect:"-"`,
}

reset_ParticleSystem :: proc(ps: ^ParticleSystem) {
	ps.duration = 5
	ps.looping = true
	ps.lifetime_min = 5
	ps.lifetime_max = 5
	ps.speed_min = 5
	ps.speed_max = 5
	ps.size_min = 1
	ps.size_max = 1
	ps.color_a = {1, 1, 1, 1}
	ps.color_b = {1, 1, 1, 1}
	ps.simulation_speed = 1
	ps.max_particles = 1000
	ps.rate = 10
	ps.shape = .Cone
	ps.shape_radius = 1
	ps.shape_angle = 25
	ps.shape_box = {1, 1, 1}
}

// The destroy path runs on_destroy (component removal, scene close, play-stop
// teardown) — without this, every destroyed system leaks its arrays.
on_destroy_ParticleSystem :: proc(ps: ^ParticleSystem) {
	cleanup_ParticleSystem(ps)
}

cleanup_ParticleSystem :: proc(ps: ^ParticleSystem) {
	delete(ps.bursts)
	delete(ps.sub_emitters)
	delete(ps.velocity_x.keys)
	delete(ps.velocity_y.keys)
	delete(ps.velocity_z.keys)
	delete(ps.orbital_x.keys)
	delete(ps.orbital_y.keys)
	delete(ps.orbital_z.keys)
	delete(ps.rotation_by_speed.keys)
	delete(ps.lifetime_by_speed.keys)
	delete(ps.force_x.keys)
	delete(ps.force_y.keys)
	delete(ps.force_z.keys)
	delete(ps.color_by_speed.keys)
	delete(ps.size_by_speed.keys)
	delete(ps.color_over_life.keys)
	delete(ps.size_over_life.keys)
	delete(ps.particles)
	engine.comp_zero(ps)
}
