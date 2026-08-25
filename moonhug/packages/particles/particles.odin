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
	// Prefab overrides on the bursts field patch through ^[dynamic]Burst.
	engine.register_pointer_type(Burst)
}

// --- Simulation ---------------------------------------------------------------

@(update={order=3})
particles_tick :: proc(dt: f32) {
	w := engine.ctx_world()
	it := engine.pool_iterator(particle_systems(w))
	for ps, _ in engine.pool_next(&it) {
		if !ps.enabled do continue
		if !engine.pool_valid(&w.transforms, engine.Handle(ps.owner)) do continue
		if !engine.transform_active_in_hierarchy(ps.owner) do continue
		system_tick(ps, dt)
	}
}

// One system's advance — public so tests drive it without a frame loop.
system_tick :: proc(ps: ^ParticleSystem, dt: f32) {
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

	for i := len(ps.particles) - 1; i >= 0; i -= 1 {
		p := &ps.particles[i]
		p.life += dt
		if p.life >= p.lifetime {
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
	emitting := ps.looping || et1 <= ps.duration

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
