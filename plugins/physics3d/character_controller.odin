package physics3d

// CharacterController (docs/components/CharacterController.md): moves an
// object by code without going through colliders. Game code calls
// character_move with how far to go this frame, gravity and jumps included,
// and the controller slides along what is in the way, walks up gentle slopes
// and low steps, and says whether it stands on the ground.
//
// - Its shape is a capsule standing upright whatever the object's rotation.
// - A move is two moves on box3d's mover (World_CollideMover gathers the
//   planes the capsule touches, SolvePlanes finds where it can go,
//   World_CastMover goes there): first across, then up or down.
//   - Across, gentle ground is walked up, and ground steeper than
//     `slope_limit` is a wall. Stopped by something no higher than
//     `step_offset` while on the ground, it tries the same move lifted by
//     that much and keeps it when that goes further and lands on ground.
//   - Up or down, gentle ground stops it, so it never creeps down a slope it
//     stands on, and steep ground slides it down.
//   - Moving across or standing on the ground, it then follows the ground
//     down as far as a step or the slope allows, so it walks down stairs and
//     slopes instead of hopping off them.
// - In the world the capsule is a kinematic body: dynamic bodies bump into
//   it and rays hit it. The fixed step moves it to the object by velocity,
//   as a kinematic Rigidbody's.
// - With no physics world, in the editor while the game does not run, a
//   move goes where it is told.

import "base:runtime"
import "core:c"
import "core:math"
import "core:math/linalg"
import b3 "vendor:box3d"
import "moonhug:packages/engine"
import "moonhug:libs/gizmos"

Collision_Flag :: enum u8 {
	Sides, // something across, a wall or a too steep slope
	Above, // a ceiling
	Below, // ground it can stand on
}
Collision_Flags :: bit_set[Collision_Flag; u8]

@(component={menu="Physics/CharacterController", icon="DIRECTIONS_RUN"})
@(typ_guid={guid = "206a30cd-c18f-4a08-a6ad-6f6c90620012"})
CharacterController :: struct {
	using base:      engine.CompData `inspect:"-"`,
	// Where the capsule's middle is, from the object's position.
	center:          [3]f32,
	radius:          f32 `decor:min(0.01)`,
	// The capsule's height, its round ends included.
	height:          f32 `decor:min(0.02)`,
	// The steepest ground it walks up, in degrees. Steeper ground is a wall,
	// and it slides down it.
	slope_limit:     f32 `decor:range(0, 89)`,
	// The highest step it walks up onto.
	step_offset:     f32 `decor:min(0)`,
	layers:          u32 `decor:layers(domain="physics3d")`,
	using layer_overrides: Physics3D_Layer_Overrides `inline:""`,

	// What the last character_move did: whether it ended on ground it can
	// stand on and that ground's normal, how far it went, what it touched.
	is_grounded:     bool `json:"-" inspect:"-"`,
	ground_normal:   [3]f32 `json:"-" inspect:"-"`,
	moved:           [3]f32 `json:"-" inspect:"-"`,
	collision_flags: Collision_Flags `json:"-" inspect:"-"`,

	body:            b3.BodyId `json:"-" inspect:"-"`,
	shape:           b3.ShapeId `json:"-" inspect:"-"`,
}

type_reset_CharacterController :: proc(cc: ^CharacterController) {
	type_cleanup_CharacterController(cc)
	cc.radius = 0.5
	cc.height = 2
	cc.slope_limit = 45
	cc.step_offset = 0.3
	cc.layers = 1
}

type_cleanup_CharacterController :: proc(cc: ^CharacterController) {
	_destroy_shape(&cc.shape, &cc.body)
	engine.comp_zero(cc)
}

// Moves the controller's object by `motion` (world units, this frame's)
// without going through colliders, and says what it touched. Reads
// `is_grounded` from the move before, so a game calls it once a frame.
character_move :: proc(cc: ^CharacterController, motion: [3]f32) -> Collision_Flags {
	if cc == nil || !cc.enabled do return {}
	w := engine.ctx_world()
	if !engine.pool_valid(&w.transforms, engine.Handle(cc.owner)) do return {}
	start := engine.transform_world(cc.owner).position
	if !_state.world_ready {
		engine.transform_set_world_position(cc.owner, start + motion)
		cc.moved, cc.is_grounded, cc.collision_flags = motion, false, {}
		return {}
	}

	m := _Move{ctx = context, cc = cc}
	m.min_ground = math.cos(math.to_radians(clamp(cc.slope_limit, 0, 89)))
	m.a, m.b, m.radius = character_capsule(cc)
	m.filter = b3.QueryFilter{categoryBits = u64(cc.layers), maskBits = u64(collision_mask(cc.layers, cc.layer_overrides, {}))}

	pos := start
	across := [3]f32{motion.x, 0, motion.z}
	if across != {} {
		plain := pos
		_slide(&m, &plain, across, .Across)
		pos = plain
		// Stopped short on the ground: a step it can walk up?
		if cc.is_grounded && cc.step_offset > 0 && motion.y <= 0 && linalg.length(plain - start) < linalg.length(across) * 0.9 {
			lifted := start + _cast(&m, start, {0, cc.step_offset, 0})
			raise := lifted.y - start.y
			_slide(&m, &lifted, across, .Across)
			landed := lifted + _cast(&m, lifted, {0, -(raise + _SKIN * 2), 0})
			if g, _ := _ground(&m, landed); g && _flat_length(landed - start) > _flat_length(plain - start) + 0.001 {
				pos = landed
			}
		}
	}
	if motion.y != 0 do _slide(&m, &pos, {0, motion.y, 0}, .Up_Down)

	grounded, normal := _ground(&m, pos)
	// Off the ground after a move across: down a step or a slope.
	if !grounded && cc.is_grounded && motion.y <= 0 {
		reach := max(cc.step_offset, _flat_length(across) * math.tan(math.acos(m.min_ground))) + _SKIN
		below := pos + _cast(&m, pos, {0, -reach, 0})
		if g, n := _ground(&m, below); g {
			pos, grounded, normal = below, true, n
		}
	}

	engine.transform_set_world_position(cc.owner, pos)
	cc.moved = pos - start
	cc.is_grounded = grounded
	cc.ground_normal = grounded ? normal : {}
	cc.collision_flags = m.touched
	if grounded do cc.collision_flags += {.Below}
	return cc.collision_flags
}

// The controller's capsule, from the object's position in world axes: the
// ends of its segment and its radius, with the object's scale.
character_capsule :: proc(cc: ^CharacterController) -> (a, b: [3]f32, radius: f32) {
	s := collider_scale(cc.owner)
	radius = cc.radius * max(s.x, s.z)
	height := max(cc.height * s.y, radius * 2)
	q := engine.quat_to_native(engine.transform_world(cc.owner).rotation)
	mid := linalg.quaternion128_mul_vector3(q, cc.center * s)
	half := height * 0.5 - radius
	return mid - {0, half, 0}, mid + {0, half, 0}, radius
}

// How far the capsule gathers planes past its surface: what it is about to
// touch slows it before it does, and the ground right under it counts.
@(private = "file")
_SKIN :: f32(0.02)

@(private = "file")
_MAX_PLANES :: 32

@(private = "file")
_Mode :: enum u8 {
	Across,
	Up_Down,
	Probe,
}

@(private = "file")
_Move :: struct {
	ctx:        runtime.Context,
	cc:         ^CharacterController,
	a, b:       [3]f32,
	radius:     f32,
	filter:     b3.QueryFilter,
	min_ground: f32, // the cosine of the slope limit
	mode:       _Mode,
	planes:     [_MAX_PLANES]b3.CollisionPlane,
	ups:        [_MAX_PLANES]f32, // each plane's normal.y as the shape gave it
	count:      int,
	touched:    Collision_Flags,
}

// Moves `pos` by `delta` as far as the world lets it, sliding along what is
// in the way.
@(private = "file")
_slide :: proc(m: ^_Move, pos: ^[3]f32, delta: [3]f32, mode: _Mode) {
	target := pos^ + delta
	for _ in 0 ..< 5 {
		_planes(m, pos^, mode)
		res := b3.SolvePlanes(target - pos^, &m.planes[0], c.int(m.count))
		for p, i in m.planes[:m.count] {
			if p.push <= 0 do continue
			switch {
			case m.ups[i] >= m.min_ground:  m.touched += {.Below}
			case m.ups[i] <= -m.min_ground: m.touched += {.Above}
			case:                           m.touched += {.Sides}
			}
		}
		step := _cast(m, pos^, res.delta)
		pos^ += step
		if linalg.length(step) < 0.0001 do break
	}
}

// How far the capsule at `pos` goes along `delta` before it touches
// something.
@(private = "file")
_cast :: proc(m: ^_Move, pos: [3]f32, delta: [3]f32) -> [3]f32 {
	if delta == {} do return {}
	mover := b3.Capsule{center1 = m.a, center2 = m.b, radius = m.radius}
	f := b3.World_CastMover(_state.world, pos, mover, delta, m.filter, _mover_filter, m)
	return delta * clamp(f, 0, 1)
}

// Whether the capsule at `pos` stands on ground it can walk on, and that
// ground's normal.
@(private = "file")
_ground :: proc(m: ^_Move, pos: [3]f32) -> (bool, [3]f32) {
	_planes(m, pos, .Probe, inflate = _SKIN * 2)
	best: f32 = -1
	normal: [3]f32
	for p, i in m.planes[:m.count] do if m.ups[i] >= m.min_ground && m.ups[i] > best {
		best = m.ups[i]
		normal = p.plane.normal
	}
	return best >= 0, normal
}

// The planes of what the capsule at `pos` touches or nearly does, made
// ready for SolvePlanes in `mode`.
@(private = "file")
_planes :: proc(m: ^_Move, pos: [3]f32, mode: _Mode, inflate := _SKIN) {
	m.count = 0
	m.mode = mode
	mover := b3.Capsule{center1 = m.a, center2 = m.b, radius = m.radius + inflate}
	b3.World_CollideMover(_state.world, pos, mover, m.filter, _plane_fcn, m)
	// The planes were found with the bigger capsule: their depth is the
	// capsule's own, a negative depth is a gap it may close.
	for &p in m.planes[:m.count] do p.plane.offset -= inflate
	for &p, i in m.planes[:m.count] {
		n := p.plane.normal
		up := m.ups[i]
		switch mode {
		case .Across:
			// Too steep to walk up: a wall, as deep across as the slope is.
			if up > 0 && up < m.min_ground {
				flat := linalg.length(n.xz)
				if flat > 0.0001 {
					p.plane.normal = {n.x / flat, 0, n.z / flat}
					p.plane.offset /= flat
				}
			}
		case .Up_Down:
			// Gentle ground holds it straight up, so it does not creep down.
			if up >= m.min_ground {
				p.plane.normal = {0, 1, 0}
				p.plane.offset /= up
			}
		case .Probe:
		}
	}
}

@(private = "file")
_plane_fcn :: proc "c" (shape: b3.ShapeId, planes: [^]b3.PlaneResult, count: c.int, ctx: rawptr) -> bool {
	m := cast(^_Move)ctx
	context = m.ctx
	if !_counts(m, shape) do return true
	for r in planes[:count] {
		if m.count >= _MAX_PLANES do return false
		m.planes[m.count] = {plane = r.plane, pushLimit = max(f32), clipVelocity = true}
		m.ups[m.count] = r.plane.normal.y
		m.count += 1
	}
	return true
}

@(private = "file")
_mover_filter :: proc "c" (shape: b3.ShapeId, ctx: rawptr) -> bool {
	m := cast(^_Move)ctx
	context = m.ctx
	return _counts(m, shape)
}

// Whether `shape` stops the controller: not a trigger, not its own capsule
// and not a collider on its object or under it.
@(private = "file")
_counts :: proc(m: ^_Move, shape: b3.ShapeId) -> bool {
	if b3.Shape_IsSensor(shape) do return false
	owner, known := _owner_of_shape(engine.ctx_world(), shape)
	return !known || !engine.transform_is_under(owner, m.cc.owner)
}

@(private = "file")
_flat_length :: proc(v: [3]f32) -> f32 {
	return linalg.length(v.xz)
}

// The controllers' capsules in the world: made on the first step, then moved
// to their objects by velocity, so what they move into is pushed.
_sync_controllers :: proc(w: ^engine.World, fixed_dt: f32) {
	it := engine.pool_iterator(character_controllers(w))
	for cc, _ in engine.pool_next(&it) {
		if !engine.pool_valid(&w.transforms, engine.Handle(cc.owner)) do continue
		mask := collision_mask(cc.layers, cc.layer_overrides, {})
		if !b3.Body_IsValid(cc.body) {
			if !cc.enabled do continue
			def := b3.DefaultBodyDef()
			def.type = .kinematicBody
			def.position = engine.transform_world(cc.owner).position
			cc.body = b3.CreateBody(_state.world, def)
			a, b, radius := character_capsule(cc)
			sdef := b3.DefaultShapeDef()
			sdef.filter.categoryBits = u64(cc.layers)
			sdef.filter.maskBits = u64(mask)
			sdef.enableContactEvents = true
			capsule := b3.Capsule{center1 = a, center2 = b, radius = radius}
			cc.shape = b3.CreateCapsuleShape(cc.body, sdef, &capsule)
			_register_shape(cc.shape, cc.owner)
			continue
		}
		if cc.enabled != b3.Body_IsEnabled(cc.body) {
			if cc.enabled do b3.Body_Enable(cc.body)
			else do b3.Body_Disable(cc.body)
		}
		_sync_filter(cc.shape, cc.layers, mask)
		if cc.enabled {
			to := engine.transform_world(cc.owner).position
			b3.Body_SetLinearVelocity(cc.body, (to - b3.Body_GetPosition(cc.body)) / fixed_dt)
		}
	}
}

// The controller's capsule as a wireframe, upright in world axes as it
// moves.
draw_character_controller_wires :: proc(cc: ^CharacterController, color: [4]f32) {
	gizmos.with_color(color)
	gizmos.in_world_space()
	a, b, radius := character_capsule(cc)
	o := engine.transform_world(cc.owner).position
	gizmos.wire_capsule(o + a, o + b, radius)
}
