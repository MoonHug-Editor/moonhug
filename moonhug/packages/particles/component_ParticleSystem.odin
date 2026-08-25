package particles

// Unity's Shuriken, range-based core: every "random between two constants"
// module field is a min/max (or color a/b) pair — curves and gradients come
// later with the curve editor. Simulation runs on the CPU per frame
// (@(update) in particles.odin), rendering goes through the renderer seam as
// billboarded Draw_Quad commands.

import "moonhug:engine"

// One live particle. Positions are in the system's simulation space.
Particle :: struct {
	position: [3]f32,
	velocity: [3]f32,
	color:    [4]f32,
	size:     f32,
	life:     f32, // seconds lived
	lifetime: f32,
}

// Emission volume, oriented along local +Z (Unity's shape axis).
Emit_Shape :: enum u8 {
	Cone,   // Unity's default: base disc of `shape_radius`, spread `shape_angle`
	Sphere, // outward from a random point inside `shape_radius`
	Point,  // straight +Z
}

Sim_Space :: enum u8 {
	Local, // particles follow the emitter (Unity's default)
	World, // particles are left behind in the world
}

@(component)
@(typ_guid={guid = "e5a7c2d1-4b3f-4c89-9a16-7d02e8b5f4a3"})
ParticleSystem :: struct {
	using base: engine.CompData `inspect:"-"`,

	// Main
	duration:     f32, // emission window in seconds (looping restarts it)
	looping:      bool,
	lifetime_min: f32,
	lifetime_max: f32,
	speed_min:    f32,
	speed_max:    f32,
	size_min:     f32, // world units (Unity's start size)
	size_max:     f32,
	color_a:      [4]f32 `decor:color()`, // start color: random between a and b
	color_b:      [4]f32 `decor:color()`,
	gravity_modifier: f32,
	sim_space:    Sim_Space,
	max_particles: i32,

	// Emission
	rate: f32, // particles per second

	// Shape
	shape:        Emit_Shape,
	shape_radius: f32,
	shape_angle:  f32, // cone spread, degrees from the axis

	// Over lifetime: linear lerp from 1 (birth) to these at death.
	// {1,1,1,1} / 1 = the module off.
	color_over_life: [4]f32 `decor:color()`,
	size_over_life:  f32,

	// Renderer: billboarded quads. The sprite is PPtr{texture guid, slice id}
	// like SpriteRenderer (the editor wrapper draws the picker), material's
	// shader/tint applies with the sprite's own texture.
	sprite:         engine.PPtr `inspect:"-"`,
	material:       engine.Asset_GUID `ext:"mat"`,
	sorting_layer:  i32,
	order_in_layer: i32,

	// Live state — never serialized, never inspected.
	particles: [dynamic]Particle `json:"-" inspect:"-"`,
	time:      f32 `json:"-" inspect:"-"`,
	emit_acc:  f32 `json:"-" inspect:"-"`,
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
	ps.max_particles = 1000
	ps.rate = 10
	ps.shape = .Cone
	ps.shape_radius = 1
	ps.shape_angle = 25
	ps.color_over_life = {1, 1, 1, 1}
	ps.size_over_life = 1
}

cleanup_ParticleSystem :: proc(ps: ^ParticleSystem) {
	delete(ps.particles)
}
