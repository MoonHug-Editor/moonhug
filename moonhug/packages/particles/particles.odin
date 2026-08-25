package particles

// Simulation + rendering for ParticleSystem (component_ParticleSystem.odin).
// The sim is plain CPU code on the @(update) phase — Unity's Shuriken model.
// Rendering registers a collector on the renderer seam and emits billboarded
// Draw_Quad commands with the shared transparent sort key, so particles
// interleave correctly with sprites by layer/order/depth.

import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "moonhug:engine"

// ImportersInit is the asset-layer init phase both binaries run — the same
// slot the sprites and animation packages use for their registrations.
@(phase={key=ImportersInit, order=3})
particles_package_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	engine.render_register_collector(_collect_particles)
	// Prefab overrides on list fields patch through ^[dynamic]T.
	engine.register_pointer_type(Burst)
	engine.register_pointer_type(Sub_Emitter)
}

// --- Simulation ---------------------------------------------------------------

@(update={order=3})
particles_tick :: proc(dt: f32) {
	w := engine.ctx_world()
	mark_sub_targets(w)
	it := engine.pool_iterator(particle_systems(w))
	for ps, _ in engine.pool_next(&it) {
		if !ps.enabled do continue
		if !engine.pool_valid(&w.transforms, engine.Handle(ps.owner)) do continue
		if !engine.transform_active_in_hierarchy(ps.owner) do continue
		system_tick(ps, dt)
	}
}

// A system referenced as a sub-emitter target does not emit on its own
// timeline — triggers drive it (Unity's rule). Recomputed before every tick
// pass; callers driving system_tick directly (the edit preview) call it too.
mark_sub_targets :: proc(w: ^engine.World) {
	it := engine.pool_iterator(particle_systems(w))
	for ps, _ in engine.pool_next(&it) {
		ps.is_sub_target = false
		ps.suppress_sub_emitters = false // editor-preview leftover
	}
	it = engine.pool_iterator(particle_systems(w))
	for ps, _ in engine.pool_next(&it) {
		for &sub in ps.sub_emitters {
			if !engine.world_pool_valid(w, sub.target.handle) do continue
			if target := cast(^ParticleSystem)engine.world_pool_get(w, sub.target.handle); target != nil {
				target.is_sub_target = true
			}
		}
	}
}

// Clears live state so the next tick starts the effect from time zero —
// the editor's edit-mode preview restarts through this, and a future
// timeline scrub is this plus a fixed-step advance to the target time.
system_reset :: proc(ps: ^ParticleSystem) {
	clear(&ps.particles)
	ps.time = 0
	ps.emit_acc = 0
	ps.dist_acc = 0
	ps.prev_pos_valid = false
	ps.prewarmed = false
	ps.seeded = false  // reseeds on the next tick
	ps.started = false // manual_start re-applies on the next tick
	ps.paused = false
	ps.stopped = false
}

// --- Playback control (Unity's Play/Pause/Stop) --------------------------------

// Starts or resumes. A stopped system restarts from time zero.
system_play :: proc(ps: ^ParticleSystem) {
	if ps.stopped do system_reset(ps)
	ps.started = true
	ps.paused = false
	ps.stopped = false
}

// Freezes the whole system — no aging, no emission — until system_play.
system_pause :: proc(ps: ^ParticleSystem) {
	ps.paused = true
}

// Stops emitting. Live particles play out, or clear immediately with
// `clear_particles` (Unity's StopEmittingAndClear).
system_stop :: proc(ps: ^ParticleSystem, clear_particles := false) {
	ps.started = true // a stop overrides a pending manual_start decision
	ps.stopped = true
	if clear_particles do clear(&ps.particles)
}

// Every random draw in the sim runs on the system's OWN stream: a nonzero
// random_seed replays the exact same effect after system_reset, seed 0 draws
// fresh entropy each reset (Unity's auto random seed).
_ensure_seeded :: proc(ps: ^ParticleSystem) {
	if ps.seeded do return
	ps.seeded = true
	seed := u64(ps.random_seed)
	if seed == 0 do seed = rand.uint64()
	ps.rand_state = rand.create(seed)
}

// One system's advance — public so tests drive it without a frame loop.
system_tick :: proc(ps: ^ParticleSystem, dt: f32) {
	// The first tick applies manual_start; pause freezes everything.
	if !ps.started {
		ps.started = true
		ps.stopped = ps.manual_start
	}
	if ps.paused do return

	_ensure_seeded(ps)
	context.random_generator = rand.default_random_generator(&ps.rand_state)

	tw := engine.transform_world(engine.Transform_Handle(ps.owner))

	// Prewarm: a looping system starts as if one full cycle already ran.
	if ps.prewarm && ps.looping && !ps.prewarmed && ps.duration > 0 {
		ps.prewarmed = true
		STEPS :: 60
		step := ps.duration / STEPS
		for _ in 0 ..< STEPS do _advance(ps, step, tw)
	}

	// 0 runs at 1: the field is zero in scenes saved before it existed.
	speed := ps.simulation_speed if ps.simulation_speed > 0 else 1
	_advance(ps, dt * speed, tw)
}

_advance :: proc(ps: ^ParticleSystem, dt: f32, tw: engine.Transform_World) {
	prev_time := ps.time
	ps.time += dt

	// Emitter speed feeds lifetime-by-speed at spawn.
	ps.emitter_speed = 0
	if ps.prev_pos_valid && dt > 0 {
		ps.emitter_speed = linalg.length(tw.position - ps.prev_pos) / dt
	}

	rot := engine.quat_to_matrix3(tw.rotation)

	// Gravity is a WORLD force: local-space sims rotate it into the
	// emitter's frame (rotation inverse = transpose).
	gravity := [3]f32{0, -9.81 * ps.gravity_modifier, 0}
	if ps.sim_space == .Local && ps.gravity_modifier != 0 {
		gravity = linalg.transpose(rot) * gravity
	}

	vel_module := len(ps.velocity_x.keys) > 0 || len(ps.velocity_y.keys) > 0 || len(ps.velocity_z.keys) > 0
	orbital_module := len(ps.orbital_x.keys) > 0 || len(ps.orbital_y.keys) > 0 || len(ps.orbital_z.keys) > 0
	force_module := len(ps.force_x.keys) > 0 || len(ps.force_y.keys) > 0 || len(ps.force_z.keys) > 0
	rot_by_speed := len(ps.rotation_by_speed.keys) > 0

	sub_death := false
	for &sub in ps.sub_emitters {
		if sub.trigger == .Death do sub_death = true
	}

	for i := len(ps.particles) - 1; i >= 0; i -= 1 {
		p := &ps.particles[i]
		p.life += dt
		if p.life >= p.lifetime {
			if sub_death {
				wp := p.position
				if ps.sim_space == .Local do wp = tw.position + rot * p.position
				_sub_emit(ps, .Death, wp) // may reallocate ps.particles — p is dead here
			}
			unordered_remove(&ps.particles, i)
			continue
		}
		p.velocity += gravity * dt

		// Force over lifetime accelerates, in the emitter's frame.
		if force_module {
			lt := clamp(p.life / p.lifetime, 0, 1)
			force := [3]f32{
				engine.curve_eval(&ps.force_x, lt, 0),
				engine.curve_eval(&ps.force_y, lt, 0),
				engine.curve_eval(&ps.force_z, lt, 0),
			}
			if ps.sim_space == .World do force = rot * force
			p.velocity += force * dt
		}

		// Limit velocity: speed above the limit decays toward it. dampen is
		// the per-frame fraction at 60 Hz, normalized so the decay is
		// frame-rate independent.
		if ps.limit_speed > 0 {
			spd := linalg.length(p.velocity)
			if spd > ps.limit_speed {
				f := 1 - math.pow(1 - clamp(ps.limit_dampen, 0, 0.9999), dt * 60)
				p.velocity *= math.lerp(spd, ps.limit_speed, f) / spd
			}
		}

		vel := p.velocity
		if vel_module {
			lt := clamp(p.life / p.lifetime, 0, 1)
			extra := [3]f32{
				engine.curve_eval(&ps.velocity_x, lt, 0),
				engine.curve_eval(&ps.velocity_y, lt, 0),
				engine.curve_eval(&ps.velocity_z, lt, 0),
			}
			// Curves are authored in the emitter's frame: world-space sims
			// rotate them out.
			if ps.sim_space == .World do extra = rot * extra
			vel += extra
		}
		p.position += vel * dt

		// Noise: deterministic smooth jitter — same field for every run, so
		// a future restart-to-time replay stays possible.
		if ps.noise_strength > 0 {
			freq := ps.noise_frequency if ps.noise_frequency > 0 else 1
			sp := p.position * freq
			sp.z += ps.time * ps.noise_scroll_speed
			p.position += _noise3(sp) * ps.noise_strength * dt
		}

		// Orbital velocity: rotate the position around the emitter's axes.
		if orbital_module {
			lt := clamp(p.life / p.lifetime, 0, 1)
			ang := [3]f32{
				math.to_radians(engine.curve_eval(&ps.orbital_x, lt, 0)),
				math.to_radians(engine.curve_eval(&ps.orbital_y, lt, 0)),
				math.to_radians(engine.curve_eval(&ps.orbital_z, lt, 0)),
			} * dt
			if ps.sim_space == .World {
				rel := linalg.transpose(rot) * (p.position - tw.position)
				p.position = tw.position + rot * _rotate_euler(rel, ang)
			} else {
				p.position = _rotate_euler(p.position, ang)
			}
		}

		p.rotation += p.angular_velocity * dt
		if rot_by_speed {
			spd := linalg.length(p.velocity)
			p.rotation += math.to_radians(engine.curve_eval(&ps.rotation_by_speed,
				speed_t(spd, ps.rotation_by_speed_min, ps.rotation_by_speed_max), 0)) * dt
		}
	}

	// Emission starts after start_delay; et is time into the first cycle.
	et0 := prev_time - ps.start_delay
	et1 := ps.time - ps.start_delay
	if et1 <= 0 {
		ps.prev_pos = tw.position
		ps.prev_pos_valid = true
		return
	}
	emitting := (ps.looping || et1 <= ps.duration) && !ps.is_sub_target && !ps.stopped

	if emitting && ps.rate > 0 {
		ps.emit_acc += ps.rate * dt
		n := int(ps.emit_acc)
		ps.emit_acc -= f32(n)
		for _ in 0 ..< n {
			if !_try_spawn(ps, tw) do break
		}
	}

	// Rate over distance: driven by the emitter's world-space movement.
	if ps.rate_over_distance > 0 && emitting && ps.prev_pos_valid {
		ps.dist_acc += linalg.length(tw.position - ps.prev_pos) * ps.rate_over_distance
		n := int(ps.dist_acc)
		ps.dist_acc -= f32(n)
		for _ in 0 ..< n {
			if !_try_spawn(ps, tw) do break
		}
	}
	ps.prev_pos = tw.position
	ps.prev_pos_valid = true

	// Bursts fire at cycle-local trigger times crossed this tick, [t0, t1).
	if len(ps.bursts) > 0 && emitting {
		t0, t1 := et0, et1
		if ps.looping && ps.duration > 0 {
			t0 = math.mod(t0, ps.duration)
			t1 = math.mod(t1, ps.duration)
		}
		if t1 >= t0 {
			_fire_bursts(ps, tw, t0, t1)
		} else { // the cycle wrapped inside this tick
			_fire_bursts(ps, tw, t0, ps.duration)
			_fire_bursts(ps, tw, 0, t1)
		}
	}
}

_fire_bursts :: proc(ps: ^ParticleSystem, tw: engine.Transform_World, t0, t1: f32) {
	for &b in ps.bursts {
		cycles := max(b.cycles, 1)
		for k in 0 ..< cycles {
			tt := b.time + f32(k) * b.interval
			if tt < t0 || tt >= t1 do continue
			if b.probability < 1 && rand.float32() >= b.probability do continue
			n := int(_rand_range(f32(b.count_min), f32(b.count_max)) + 0.5)
			for _ in 0 ..< n {
				if !_try_spawn(ps, tw) do break
			}
		}
	}
}

_try_spawn :: proc(ps: ^ParticleSystem, tw: engine.Transform_World) -> bool {
	if i32(len(ps.particles)) >= max(ps.max_particles, 0) do return false
	_spawn(ps, tw)
	return true
}

_rand_range :: proc(lo, hi: f32) -> f32 {
	if hi <= lo do return lo
	return lo + rand.float32() * (hi - lo)
}

_rand_unit :: proc() -> [3]f32 {
	for {
		v := [3]f32{_rand_range(-1, 1), _rand_range(-1, 1), _rand_range(-1, 1)}
		l2 := linalg.length2(v)
		if l2 > 1 || l2 < 1e-6 do continue
		return v / math.sqrt(l2)
	}
}

_spawn :: proc(ps: ^ParticleSystem, tw: engine.Transform_World) {
	// Shape sample in LOCAL space, axis +Z (Unity's).
	pos: [3]f32
	dir := [3]f32{0, 0, 1}
	switch ps.shape {
	case .Point:
	case .Sphere, .Hemisphere:
		v := _rand_unit() * math.pow(rand.float32(), 1.0 / 3) // uniform in volume
		if ps.shape == .Hemisphere && v.z < 0 do v.z = -v.z
		pos = v * ps.shape_radius
		dir = linalg.normalize(v)
	case .Cone:
		theta := rand.float32() * math.TAU
		pos = [3]f32{math.cos(theta), math.sin(theta), 0} * (ps.shape_radius * math.sqrt(rand.float32()))
		a := math.to_radians(clamp(ps.shape_angle, 0, 89)) * rand.float32()
		sa := math.sin(a)
		phi := rand.float32() * math.TAU
		dir = linalg.normalize([3]f32{sa * math.cos(phi), sa * math.sin(phi), math.cos(a)})
	case .Circle:
		theta := rand.float32() * math.TAU
		radial := [3]f32{math.cos(theta), math.sin(theta), 0}
		pos = radial * (ps.shape_radius * math.sqrt(rand.float32()))
		dir = radial
	case .Edge:
		pos = [3]f32{_rand_range(-1, 1) * ps.shape_radius, 0, 0}
	case .Box:
		pos = [3]f32{
			_rand_range(-0.5, 0.5) * ps.shape_box.x,
			_rand_range(-0.5, 0.5) * ps.shape_box.y,
			_rand_range(-0.5, 0.5) * ps.shape_box.z,
		}
	}

	if ps.spherize_direction > 0 && linalg.length2(pos) > 1e-8 {
		dir = linalg.lerp(dir, linalg.normalize(pos), clamp(ps.spherize_direction, 0, 1))
		if linalg.length2(dir) > 1e-8 do dir = linalg.normalize(dir)
	}
	if ps.randomize_direction > 0 {
		dir = linalg.lerp(dir, _rand_unit(), clamp(ps.randomize_direction, 0, 1))
		if linalg.length2(dir) > 1e-8 do dir = linalg.normalize(dir)
	}

	if ps.sim_space == .World {
		rot := engine.quat_to_matrix3(tw.rotation)
		pos = tw.position + rot * pos
		dir = rot * dir
	}

	rot0 := math.to_radians(_rand_range(ps.rotation_min, ps.rotation_max))
	ang := math.to_radians(_rand_range(ps.angular_velocity_min, ps.angular_velocity_max))
	if ps.flip_rotation > 0 && rand.float32() < ps.flip_rotation {
		rot0 = -rot0
		ang = -ang
	}

	lifetime := _rand_range(ps.lifetime_min, ps.lifetime_max)
	if len(ps.lifetime_by_speed.keys) > 0 {
		lifetime *= engine.curve_eval(&ps.lifetime_by_speed,
			speed_t(ps.emitter_speed, ps.lifetime_by_speed_min, ps.lifetime_by_speed_max))
	}

	t := rand.float32()
	append(&ps.particles, Particle{
		position         = pos,
		velocity         = dir * _rand_range(ps.speed_min, ps.speed_max),
		color            = linalg.lerp(ps.color_a, ps.color_b, t),
		size             = _rand_range(ps.size_min, ps.size_max),
		rotation         = rot0,
		angular_velocity = ang,
		lifetime         = max(lifetime, 0.01),
	})

	if len(ps.sub_emitters) > 0 {
		wp := pos
		if ps.sim_space == .Local {
			rot := engine.quat_to_matrix3(tw.rotation)
			wp = tw.position + rot * pos
		}
		_sub_emit(ps, .Birth, wp)
	}
}

// Chained and self-targeting sub emitters recurse through _spawn — the
// depth guard bounds them (Unity limits sub-emitter chains the same way).
@(private = "file") _sub_depth: int

_sub_emit :: proc(ps: ^ParticleSystem, trigger: Sub_Emitter_Trigger, world_pos: [3]f32) {
	if len(ps.sub_emitters) == 0 || ps.suppress_sub_emitters do return
	if _sub_depth >= 4 do return
	_sub_depth += 1
	defer _sub_depth -= 1

	w := engine.ctx_world()
	for &sub in ps.sub_emitters {
		if sub.trigger != trigger do continue
		if !engine.world_pool_valid(w, sub.target.handle) do continue
		target := cast(^ParticleSystem)engine.world_pool_get(w, sub.target.handle)
		if target == nil || !target.enabled do continue
		if sub.probability < 1 && rand.float32() >= sub.probability do continue
		system_emit_at(target, world_pos)
	}
}

// Fires the system's authored bursts once, anchored at `world_pos` instead
// of its emitter transform — the shape offset is kept. Draws on the system's
// own random stream so its replay stays deterministic. Public: sub emitters
// trigger through it, gameplay code and the editor's Emit button call it
// directly (Unity's ParticleSystem.Emit).
system_emit_at :: proc(ps: ^ParticleSystem, world_pos: [3]f32) {
	_ensure_seeded(ps)
	context.random_generator = rand.default_random_generator(&ps.rand_state)
	tw := engine.transform_world(engine.Transform_Handle(ps.owner))

	before := len(ps.particles)
	for &b in ps.bursts {
		if b.probability < 1 && rand.float32() >= b.probability do continue
		n := int(_rand_range(f32(b.count_min), f32(b.count_max)) + 0.5)
		for _ in 0 ..< n {
			if !_try_spawn(ps, tw) do break
		}
	}

	// Re-anchor the new particles from the emitter transform to the trigger.
	if ps.sim_space == .World {
		delta := world_pos - tw.position
		for i in before ..< len(ps.particles) do ps.particles[i].position += delta
	} else {
		rot := engine.quat_to_matrix3(tw.rotation)
		local := linalg.transpose(rot) * (world_pos - tw.position)
		for i in before ..< len(ps.particles) do ps.particles[i].position += local
	}
}

// Smooth value noise for the noise module: hashed lattice corners blended
// with smoothstep weights, one independent channel per axis. Deterministic —
// the same position always samples the same value.
@(private = "file")
_noise_hash :: proc(x, y, z: i32, seed: u32) -> f32 {
	h := u32(x) * 0x8da6b343 + u32(y) * 0xd8163841 + u32(z) * 0xcb1ab31f + seed * 0x9e3779b9
	h ~= h >> 13
	h *= 0x85ebca6b
	h ~= h >> 16
	return f32(h & 0xffffff) / f32(0xffffff) * 2 - 1
}

@(private = "file")
_value_noise :: proc(p: [3]f32, seed: u32) -> f32 {
	fx := math.floor(p.x)
	fy := math.floor(p.y)
	fz := math.floor(p.z)
	x, y, z := i32(fx), i32(fy), i32(fz)
	sm :: proc(t: f32) -> f32 { return t * t * (3 - 2 * t) }
	tx, ty, tz := sm(p.x - fx), sm(p.y - fy), sm(p.z - fz)

	c000 := _noise_hash(x, y, z, seed)
	c100 := _noise_hash(x + 1, y, z, seed)
	c010 := _noise_hash(x, y + 1, z, seed)
	c110 := _noise_hash(x + 1, y + 1, z, seed)
	c001 := _noise_hash(x, y, z + 1, seed)
	c101 := _noise_hash(x + 1, y, z + 1, seed)
	c011 := _noise_hash(x, y + 1, z + 1, seed)
	c111 := _noise_hash(x + 1, y + 1, z + 1, seed)

	x00 := math.lerp(c000, c100, tx)
	x10 := math.lerp(c010, c110, tx)
	x01 := math.lerp(c001, c101, tx)
	x11 := math.lerp(c011, c111, tx)
	return math.lerp(math.lerp(x00, x10, ty), math.lerp(x01, x11, ty), tz)
}

@(private = "file")
_noise3 :: proc(p: [3]f32) -> [3]f32 {
	return {
		_value_noise(p, 0x51ed270b),
		_value_noise(p, 0x9f2d3481),
		_value_noise(p, 0x3c6ef372),
	}
}

// Rotates around x, then y, then z.
_rotate_euler :: proc(v: [3]f32, a: [3]f32) -> [3]f32 {
	r := v
	c := math.cos(a.x)
	s := math.sin(a.x)
	r = {r.x, r.y * c - r.z * s, r.y * s + r.z * c}
	c = math.cos(a.y)
	s = math.sin(a.y)
	r = {r.x * c + r.z * s, r.y, -r.x * s + r.z * c}
	c = math.cos(a.z)
	s = math.sin(a.z)
	r = {r.x * c - r.y * s, r.x * s + r.y * c, r.z}
	return r
}

// Remaps a particle's speed from [lo, hi] to 0..1 for the by-speed modules.
// Public so tests cover the mapping without a GPU.
speed_t :: proc(spd, lo, hi: f32) -> f32 {
	span := hi - lo
	if span <= 1e-6 do return 0 if spd < lo else 1
	return clamp((spd - lo) / span, 0, 1)
}

// --- Rendering ------------------------------------------------------------------

_collect_particles :: proc(view: engine.Render_View, out: ^[dynamic]engine.Render_Command) {
	w := engine.ctx_world()

	// Camera basis for billboarding: view matrix rows are right and up.
	right := [3]f32{view.view[0, 0], view.view[0, 1], view.view[0, 2]}
	up := [3]f32{view.view[1, 0], view.view[1, 1], view.view[1, 2]}

	seq: u16 = 0
	it := engine.pool_iterator(particle_systems(w))
	for ps, _ in engine.pool_next(&it) {
		if !ps.enabled || len(ps.particles) == 0 do continue
		if engine.asset_guid_is_empty(ps.sprite.guid) do continue
		t := engine.pool_get(&w.transforms, engine.Handle(ps.owner))
		if t == nil || !engine.transform_active_in_hierarchy(ps.owner) do continue
		if t.render_layer & view.layer_mask == 0 do continue

		tex, tok := engine.texture_load(ps.sprite.guid)
		if !tok do continue
		uvs := engine.QUAD_UVS_FULL
		if ps.sprite.local_id != 0 {
			s, found := engine.texture_sprite_rect(tex, ps.sprite.local_id)
			if !found do continue
			u0 := s.rect.x / f32(tex.width)
			u1 := (s.rect.x + s.rect.z) / f32(tex.width)
			v_top := s.rect.y / f32(tex.height)
			v_bottom := (s.rect.y + s.rect.w) / f32(tex.height)
			uvs = {{u0, v_bottom}, {u1, v_bottom}, {u1, v_top}, {u0, v_top}}
		}

		// Local-space particles ride the emitter's CURRENT transform.
		tw := engine.transform_world(engine.Transform_Handle(ps.owner))
		rot := engine.quat_to_matrix3(tw.rotation)

		forward := [3]f32{view.view[2, 0], view.view[2, 1], view.view[2, 2]}
		color_by_speed := len(ps.color_by_speed.keys) > 0
		size_by_speed := len(ps.size_by_speed.keys) > 0

		for &p in ps.particles {
			wp := p.position
			vel := p.velocity
			if ps.sim_space == .Local {
				wp = tw.position + rot * p.position
				vel = rot * vel
			}
			lt := clamp(p.life / p.lifetime, 0, 1)
			size := p.size * engine.curve_eval(&ps.size_over_life, lt)
			color := p.color * engine.gradient_eval(&ps.color_over_life, lt)
			spd := linalg.length(vel)
			if color_by_speed {
				color *= engine.gradient_eval(&ps.color_by_speed,
					speed_t(spd, ps.color_by_speed_min, ps.color_by_speed_max))
			}
			if size_by_speed {
				size *= engine.curve_eval(&ps.size_by_speed,
					speed_t(spd, ps.size_by_speed_min, ps.size_by_speed_max))
			}
			half := size * 0.5
			seq += 1

			// Quad basis: camera-facing rolled by the particle's angle, or
			// aligned to velocity for stretched billboards.
			r, u := right, up
			half_r, half_u := half, half
			if ps.render_mode == .Stretched && spd > 1e-4 {
				dir := vel / spd
				side := linalg.cross(dir, forward)
				if linalg.length2(side) < 1e-6 do side = right // velocity into the screen
				r = dir
				u = linalg.normalize(side)
				length_scale := ps.stretch_length_scale if ps.stretch_length_scale > 0 else 1
				half_r = (size * length_scale + spd * ps.stretch_speed_scale) * 0.5
			} else if p.rotation != 0 {
				c := math.cos(p.rotation)
				s := math.sin(p.rotation)
				r = right * c + up * s
				u = up * c - right * s
			}

			key: engine.Sort_Key
			key[0] = engine.sort_key_word(ps.sorting_layer, ps.order_in_layer,
				engine.sort_key_depth(view, wp), seq)
			append(out, engine.Render_Command{
				key     = key,
				variant = engine.Draw_Quad{
					texture  = ps.sprite.guid,
					material = ps.material,
					corners  = {
						wp - r * half_r - u * half_u,
						wp + r * half_r - u * half_u,
						wp + r * half_r + u * half_u,
						wp - r * half_r + u * half_u,
					},
					uvs   = uvs,
					color = color,
				},
			})
		}
	}
}
