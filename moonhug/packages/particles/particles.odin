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
	ps.time += dt

	// Gravity is a WORLD force: local-space sims rotate it into the
	// emitter's frame (rotation inverse = transpose).
	gravity := [3]f32{0, -9.81 * ps.gravity_modifier, 0}
	tw := engine.transform_world(engine.Transform_Handle(ps.owner))
	if ps.sim_space == .Local && ps.gravity_modifier != 0 {
		rot := engine.quat_to_matrix3(tw.rotation)
		gravity = linalg.transpose(rot) * gravity
	}

	for i := len(ps.particles) - 1; i >= 0; i -= 1 {
		p := &ps.particles[i]
		p.life += dt
		if p.life >= p.lifetime {
			unordered_remove(&ps.particles, i)
			continue
		}
		p.velocity += gravity * dt
		p.position += p.velocity * dt
	}

	emitting := ps.looping || ps.time <= ps.duration
	if emitting && ps.rate > 0 {
		ps.emit_acc += ps.rate * dt
		n := int(ps.emit_acc)
		ps.emit_acc -= f32(n)
		for _ in 0 ..< n {
			if i32(len(ps.particles)) >= max(ps.max_particles, 0) do break
			_spawn(ps, tw)
		}
	}
}

_rand_range :: proc(lo, hi: f32) -> f32 {
	if hi <= lo do return lo
	return lo + rand.float32() * (hi - lo)
}

_spawn :: proc(ps: ^ParticleSystem, tw: engine.Transform_World) {
	// Shape sample in LOCAL space, axis +Z (Unity's).
	pos: [3]f32
	dir := [3]f32{0, 0, 1}
	switch ps.shape {
	case .Point:
	case .Sphere:
		for {
			v := [3]f32{_rand_range(-1, 1), _rand_range(-1, 1), _rand_range(-1, 1)}
			if linalg.length2(v) > 1 || linalg.length2(v) < 1e-6 do continue
			pos = v * ps.shape_radius
			dir = linalg.normalize(v)
			break
		}
	case .Cone:
		theta := rand.float32() * math.TAU
		pos = [3]f32{math.cos(theta), math.sin(theta), 0} * (ps.shape_radius * math.sqrt(rand.float32()))
		a := math.to_radians(clamp(ps.shape_angle, 0, 89)) * rand.float32()
		sa := math.sin(a)
		phi := rand.float32() * math.TAU
		dir = linalg.normalize([3]f32{sa * math.cos(phi), sa * math.sin(phi), math.cos(a)})
	}

	if ps.sim_space == .World {
		rot := engine.quat_to_matrix3(tw.rotation)
		pos = tw.position + rot * pos
		dir = rot * dir
	}

	t := rand.float32()
	append(&ps.particles, Particle{
		position = pos,
		velocity = dir * _rand_range(ps.speed_min, ps.speed_max),
		color    = linalg.lerp(ps.color_a, ps.color_b, t),
		size     = _rand_range(ps.size_min, ps.size_max),
		lifetime = max(_rand_range(ps.lifetime_min, ps.lifetime_max), 0.01),
	})
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

		for &p in ps.particles {
			wp := p.position
			if ps.sim_space == .Local {
				wp = tw.position + rot * p.position
			}
			lt := clamp(p.life / p.lifetime, 0, 1)
			size := p.size * math.lerp(f32(1), ps.size_over_life, lt)
			color := p.color * linalg.lerp([4]f32{1, 1, 1, 1}, ps.color_over_life, lt)
			half := size * 0.5
			seq += 1

			key: engine.Sort_Key
			key[0] = engine.sort_key_word(ps.sorting_layer, ps.order_in_layer,
				engine.sort_key_depth(view, wp), seq)
			append(out, engine.Render_Command{
				key     = key,
				variant = engine.Draw_Quad{
					texture  = ps.sprite.guid,
					material = ps.material,
					corners  = {
						wp - right * half - up * half,
						wp + right * half - up * half,
						wp + right * half + up * half,
						wp - right * half + up * half,
					},
					uvs   = uvs,
					color = color,
				},
			})
		}
	}
}
