package physics2d

// CharacterController2D (docs/components/CharacterController2D.md): the 2D
// sibling of physics3d's CharacterController. Game code calls
// character_move with how far to go this frame, gravity and jumps included,
// and the controller slides along what is in the way, walks up gentle slopes
// and low steps, and says whether it stands on the ground.
//
// - Its shape is a capsule standing upright whatever the object's rotation.
// - A move is two moves on box2d's mover (World_CollideMover gathers the
//   planes the capsule touches, SolvePlanes finds where it can go,
//   World_CastMover goes there): first across, then up or down. Across,
//   ground steeper than `slope_limit` is a wall, and a step no higher than
//   `step_offset` is walked up. Up or down, gentle ground stops it and steep
//   ground slides it down. Then it follows the ground down a step or a slope.
// - box2d's mover cast takes no filter callback, so the controller's queries
//   ask for one category, MOVER_QUERY_BIT, which every solid collider's mask
//   has. Triggers and the controllers' own capsules leave it out, so they
//   never stop a controller.
// - In the world the capsule is a kinematic body moved to its object by
//   velocity: dynamic bodies bump into it and rays hit it.
// - With no physics world, in the editor while the game does not run, a
//   move goes where it is told.

import "base:runtime"
import "core:math"
import "core:math/linalg"
import b2 "vendor:box2d"
import "moonhug:packages/engine"
import "moonhug:libs/gizmos"

// In the mask of every solid collider's shape, the one category a
// CharacterController2D's queries ask for. No layer is this bit, so it
// changes no collision between shapes.
MOVER_QUERY_BIT :: u64(1) << 63

Collision_Flag :: enum u8 {
	Sides, // something across, a wall or a too steep slope
	Above, // a ceiling
	Below, // ground it can stand on
}
Collision_Flags :: bit_set[Collision_Flag; u8]

@(component={menu="Physics2D/CharacterController2D"})
@(typ_guid={guid = "e8f04b69-f8df-44ea-bb87-cda4965cde18"})
CharacterController2D :: struct {
	using base:      engine.CompData `inspect:"-"`,
	// Where the capsule's middle is, from the object's position.
	offset:          [2]f32,
	radius:          f32 `decor:min(0.01)`,
	// The capsule's height, its round ends included.
	height:          f32 `decor:min(0.02)`,
	// The steepest ground it walks up, in degrees. Steeper ground is a wall,
	// and it slides down it.
	slope_limit:     f32 `decor:range(0, 89)`,
	// The highest step it walks up onto.
	step_offset:     f32 `decor:min(0)`,
	layers:          u32 `decor:layers(domain="physics2d")`,
	using layer_overrides: Physics2D_Layer_Overrides `inline:""`,

	// What the last character_move did: whether it ended on ground it can
	// stand on and that ground's normal, how far it went, what it touched.
	is_grounded:     bool `json:"-" inspect:"-"`,
	ground_normal:   [2]f32 `json:"-" inspect:"-"`,
	moved:           [2]f32 `json:"-" inspect:"-"`,
	collision_flags: Collision_Flags `json:"-" inspect:"-"`,

	body:            b2.BodyId `json:"-" inspect:"-"`,
	shape:           b2.ShapeId `json:"-" inspect:"-"`,
}

type_reset_CharacterController2D :: proc(cc: ^CharacterController2D) {
	type_cleanup_CharacterController2D(cc)
	cc.radius = 0.5
	cc.height = 2
	cc.slope_limit = 45
	cc.step_offset = 0.3
	cc.layers = 1
}

type_cleanup_CharacterController2D :: proc(cc: ^CharacterController2D) {
	_destroy_shape(&cc.shape, &cc.body)
	engine.comp_zero(cc)
}

// Moves the controller's object by `motion` (world units, this frame's)
// without going through colliders, and says what it touched. Reads
// `is_grounded` from the move before, so a game calls it once a frame.
character_move :: proc(cc: ^CharacterController2D, motion: [2]f32) -> Collision_Flags {
	if cc == nil || !cc.enabled do return {}
	w := engine.ctx_world()
	if !engine.pool_valid(&w.transforms, engine.Handle(cc.owner)) do return {}
	world_pos := engine.transform_world(cc.owner).position
	start := world_pos.xy
	if !_state.world_ready {
		engine.transform_set_world_position(cc.owner, world_pos + {motion.x, motion.y, 0})
		cc.moved, cc.is_grounded, cc.collision_flags = motion, false, {}
		return {}
	}

	m := _Move2{ctx = context, cc = cc}
	m.min_ground = math.cos(math.to_radians(clamp(cc.slope_limit, 0, 89)))
	m.a, m.b, m.radius = character_capsule_2d(cc)
	// The query category every solid collider's mask has (MOVER_QUERY_BIT).
	m.filter = b2.QueryFilter{categoryBits = MOVER_QUERY_BIT, maskBits = u64(collision_mask(cc.layers, cc.layer_overrides, {}))}

	pos := start
	across := [2]f32{motion.x, 0}
	if across != {} {
		plain := pos
		_slide2(&m, &plain, across, .Across)
		pos = plain
		if cc.is_grounded && cc.step_offset > 0 && motion.y <= 0 && abs(plain.x - start.x) < abs(across.x) * 0.9 {
			lifted := start + _cast2(&m, start, {0, cc.step_offset})
			raise := lifted.y - start.y
			_slide2(&m, &lifted, across, .Across)
			landed := lifted + _cast2(&m, lifted, {0, -(raise + _SKIN2 * 2)})
			if g, _ := _ground2(&m, landed); g && abs(landed.x - start.x) > abs(plain.x - start.x) + 0.001 {
				pos = landed
			}
		}
	}
	if motion.y != 0 do _slide2(&m, &pos, {0, motion.y}, .Up_Down)

	grounded, normal := _ground2(&m, pos)
	if !grounded && cc.is_grounded && motion.y <= 0 {
		reach := max(cc.step_offset, abs(across.x) * math.tan(math.acos(m.min_ground))) + _SKIN2
		below := pos + _cast2(&m, pos, {0, -reach})
		if g, n := _ground2(&m, below); g {
			pos, grounded, normal = below, true, n
		}
	}

	engine.transform_set_world_position(cc.owner, {pos.x, pos.y, world_pos.z})
	cc.moved = pos - start
	cc.is_grounded = grounded
	cc.ground_normal = grounded ? normal : {}
	cc.collision_flags = m.touched
	if grounded do cc.collision_flags += {.Below}
	return cc.collision_flags
}

// The controller's capsule, from the object's position in world axes: the
// ends of its segment and its radius, with the object's scale.
character_capsule_2d :: proc(cc: ^CharacterController2D) -> (a, b: [2]f32, radius: f32) {
	s := collider_scale(cc.owner)
	radius = cc.radius * abs(s.x)
	height := max(cc.height * abs(s.y), radius * 2)
	mid := _rotate2(cc.offset * s, _world_z_angle(engine.transform_world(cc.owner).rotation))
	half := height * 0.5 - radius
	return mid - {0, half}, mid + {0, half}, radius
}

@(private = "file")
_SKIN2 :: f32(0.02)

@(private = "file")
_MAX_PLANES2 :: 32

@(private = "file")
_Mode2 :: enum u8 {
	Across,
	Up_Down,
	Probe,
}

@(private = "file")
_Move2 :: struct {
	ctx:        runtime.Context,
	cc:         ^CharacterController2D,
	a, b:       [2]f32,
	radius:     f32,
	filter:     b2.QueryFilter,
	min_ground: f32,
	inflate:    f32,
	planes:     [_MAX_PLANES2]b2.CollisionPlane,
	ups:        [_MAX_PLANES2]f32,
	count:      int,
	touched:    Collision_Flags,
}

@(private = "file")
_slide2 :: proc(m: ^_Move2, pos: ^[2]f32, delta: [2]f32, mode: _Mode2) {
	target := pos^ + delta
	for _ in 0 ..< 5 {
		_planes2(m, pos^, mode)
		res := b2.SolvePlanes(target - pos^, m.planes[:m.count])
		for p, i in m.planes[:m.count] {
			if p.push <= 0 do continue
			switch {
			case m.ups[i] >= m.min_ground:  m.touched += {.Below}
			case m.ups[i] <= -m.min_ground: m.touched += {.Above}
			case:                           m.touched += {.Sides}
			}
		}
		step := _cast2(m, pos^, res.translation)
		pos^ += step
		if linalg.length(step) < 0.0001 do break
	}
}

@(private = "file")
_cast2 :: proc(m: ^_Move2, pos: [2]f32, delta: [2]f32) -> [2]f32 {
	if delta == {} do return {}
	mover := b2.Capsule{center1 = pos + m.a, center2 = pos + m.b, radius = m.radius}
	f := b2.World_CastMover(_state.world, mover, delta, m.filter)
	return delta * clamp(f, 0, 1)
}

@(private = "file")
_ground2 :: proc(m: ^_Move2, pos: [2]f32) -> (bool, [2]f32) {
	_planes2(m, pos, .Probe, inflate = _SKIN2 * 2)
	best: f32 = -1
	normal: [2]f32
	for p, i in m.planes[:m.count] do if m.ups[i] >= m.min_ground && m.ups[i] > best {
		best = m.ups[i]
		normal = p.plane.normal
	}
	return best >= 0, normal
}

@(private = "file")
_planes2 :: proc(m: ^_Move2, pos: [2]f32, mode: _Mode2, inflate := _SKIN2) {
	m.count = 0
	m.inflate = inflate
	mover := b2.Capsule{center1 = pos + m.a, center2 = pos + m.b, radius = m.radius + inflate}
	b2.World_CollideMover(_state.world, mover, m.filter, _plane_fcn2, m)
	for &p, i in m.planes[:m.count] {
		p.plane.offset -= inflate
		n := p.plane.normal
		up := m.ups[i]
		switch mode {
		case .Across:
			if up > 0 && up < m.min_ground && abs(n.x) > 0.0001 {
				p.plane.normal = {math.sign(n.x), 0}
				p.plane.offset /= abs(n.x)
			}
		case .Up_Down:
			if up >= m.min_ground {
				p.plane.normal = {0, 1}
				p.plane.offset /= up
			}
		case .Probe:
		}
	}
}

@(private = "file")
_plane_fcn2 :: proc "c" (shape: b2.ShapeId, r: ^b2.PlaneResult, ctx: rawptr) -> bool {
	m := cast(^_Move2)ctx
	context = m.ctx
	if !r.hit do return true
	if owner, known := _owner_of_shape(engine.ctx_world(), shape); known && engine.transform_is_under(owner, m.cc.owner) do return true
	if m.count >= _MAX_PLANES2 do return false
	m.planes[m.count] = {plane = r.plane, pushLimit = max(f32), clipVelocity = true}
	m.ups[m.count] = r.plane.normal.y
	m.count += 1
	return true
}

// The controllers' capsules in the world: made on the first step, then moved
// to their objects by velocity, so what they move into is pushed. Their
// masks leave out MOVER_QUERY_BIT: a controller never stops on its own.
_sync_controllers :: proc(w: ^engine.World, fixed_dt: f32) {
	it := engine.pool_iterator(character_controller2_ds(w))
	for cc, _ in engine.pool_next(&it) {
		if !engine.pool_valid(&w.transforms, engine.Handle(cc.owner)) do continue
		mask := collision_mask(cc.layers, cc.layer_overrides, {})
		if !b2.Body_IsValid(cc.body) {
			if !cc.enabled do continue
			def := b2.DefaultBodyDef()
			def.type = .kinematicBody
			def.position = engine.transform_world(cc.owner).position.xy
			cc.body = b2.CreateBody(_state.world, def)
			a, b, radius := character_capsule_2d(cc)
			sdef := b2.DefaultShapeDef()
			sdef.filter.categoryBits = u64(cc.layers)
			sdef.filter.maskBits = u64(mask)
			sdef.enableContactEvents = true
			capsule := b2.Capsule{center1 = a, center2 = b, radius = radius}
			cc.shape = b2.CreateCapsuleShape(cc.body, sdef, &capsule)
			_register_shape(cc.shape, cc.owner)
			continue
		}
		if cc.enabled != b2.Body_IsEnabled(cc.body) {
			if cc.enabled do b2.Body_Enable(cc.body)
			else do b2.Body_Disable(cc.body)
		}
		_sync_filter(cc.shape, cc.layers, mask, stops_movers = false)
		if cc.enabled {
			to := engine.transform_world(cc.owner).position.xy
			b2.Body_SetLinearVelocity(cc.body, (to - b2.Body_GetPosition(cc.body)) / fixed_dt)
		}
	}
}

// The controller's capsule as an outline, upright in world axes as it moves.
draw_character_controller_2d_wires :: proc(cc: ^CharacterController2D, color: [4]f32) {
	gizmos.with_color(color)
	gizmos.in_world_space()
	a, b, radius := character_capsule_2d(cc)
	p := engine.transform_world(cc.owner).position
	top := [3]f32{p.x + b.x, p.y + b.y, p.z}
	bottom := [3]f32{p.x + a.x, p.y + a.y, p.z}
	gizmos.wire_arc(top, {0, 0, 1}, {1, 0, 0}, math.PI, radius)
	gizmos.wire_arc(bottom, {0, 0, 1}, {-1, 0, 0}, math.PI, radius)
	gizmos.line(top + {radius, 0, 0}, bottom + {radius, 0, 0})
	gizmos.line(top - {radius, 0, 0}, bottom - {radius, 0, 0})
}
