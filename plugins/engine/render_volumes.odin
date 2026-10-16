package engine

// Volumes applied to a view (component_Volume.odin): for each step of the
// lane the view runs, the pipeline's settings with every active volume's
// override for that step blended in, by the volume's weight at the camera,
// lowest priority first. A frame without an active volume costs a look at
// the pool. Each override's JSON is parsed once and kept until its text
// changes.

import "base:runtime"
import "core:encoding/json"
import "core:hash"
import "core:math/linalg"
import "core:slice"
import "moonhug:libs/log"

// How much of `v` applies at `point`: its weight inside the box (or
// everywhere, when global), fading to 0 over blend_distance outside it.
volume_weight :: proc(v: ^Volume, tw: Transform_World, point: [3]f32) -> f32 {
	weight := clamp(v.weight, 0, 1)
	if v.global do return weight
	// Into the box's space, its scale kept: the box is size times scale.
	local := linalg.quaternion128_mul_vector3(linalg.quaternion_inverse(quat_to_native(tw.rotation)), point - tw.position)
	half := v.size * 0.5 * tw.scale
	outside := [3]f32{max(abs(local.x) - half.x, 0), max(abs(local.y) - half.y, 0), max(abs(local.z) - half.z, 0)}
	dist := linalg.length(outside)
	if dist <= 0 do return weight
	if v.blend_distance <= 0 do return 0
	return weight * clamp(1 - dist / v.blend_distance, 0, 1)
}

// Moves the settings struct at `dst` (of `tid`) toward the one at `src` by
// `t`: numbers, alone or in arrays, interpolate, everything else (switches,
// enums, assets) takes src's value once t reaches a half.
settings_blend :: proc(tid: typeid, dst, src: rawptr, t: f32) {
	_blend_value(type_info_of(tid), dst, src, t)
}

@(private = "file")
_blend_value :: proc(ti: ^runtime.Type_Info, dst, src: rawptr, t: f32) {
	#partial switch v in ti.variant {
	case runtime.Type_Info_Named:
		_blend_value(v.base, dst, src, t)
	case runtime.Type_Info_Struct:
		for i in 0 ..< v.field_count {
			off := v.offsets[i]
			_blend_value(v.types[i], rawptr(uintptr(dst) + off), rawptr(uintptr(src) + off), t)
		}
	case runtime.Type_Info_Array:
		for i in 0 ..< v.count {
			off := uintptr(i * v.elem_size)
			_blend_value(v.elem, rawptr(uintptr(dst) + off), rawptr(uintptr(src) + off), t)
		}
	case runtime.Type_Info_Float:
		switch ti.size {
		case 4:
			d := (^f32)(dst)
			d^ += ((^f32)(src)^ - d^) * t
		case 8:
			d := (^f64)(dst)
			d^ += ((^f64)(src)^ - d^) * f64(t)
		}
	case:
		if t >= 0.5 do runtime.mem_copy(dst, src, ti.size)
	}
}

// Fills `buf` (step.settings_size bytes) with the step's defaults and
// `text` (JSON, the whole block or a part of it) applied over them. False
// when the text does not parse as the settings type, `buf` then holds the
// defaults.
render_step_settings_parse :: proc(step: ^Render_Step, text: string, buf: []u8) -> bool {
	assert(len(buf) == step.settings_size, "render_step_settings_parse: the buffer is the settings' size")
	runtime.mem_copy(raw_data(buf), step.settings_default, step.settings_size)
	if text == "" do return true
	pp := raw_data(buf)
	return json.unmarshal_any(transmute([]u8)text, any{&pp, step.settings_ptr_tid}, .JSON, context.temp_allocator) == nil
}

// The settings each step of `lane` runs with for a view whose camera is at
// `cam_pos`: nil when the volumes change nothing for the step (the
// pipeline's own apply), else a temp-allocated blend. nil altogether when no
// volume is active.
_volumes_settings :: proc(lane: []Pipeline_Instance, cam_pos: [3]f32) -> []rawptr {
	Active :: struct {
		v:        ^Volume,
		weight:   f32,
		priority: i32,
	}
	// A run with no user context or world (a test's bare pipeline) has no volumes.
	if ctx_get() == nil do return nil
	world := ctx_world()
	if world == nil do return nil
	active := make([dynamic]Active, context.temp_allocator)
	it := pool_iterator(volumes(world))
	for v, _ in pool_next(&it) {
		if !v.enabled || len(v.overrides) == 0 || !transform_active_in_hierarchy(v.owner) do continue
		w := volume_weight(v, transform_world(Transform_Handle(v.owner)), cam_pos)
		if w <= 0 do continue
		append(&active, Active{v, w, v.priority})
	}
	if len(active) == 0 do return nil
	slice.stable_sort_by(active[:], proc(a, b: Active) -> bool { return a.priority < b.priority })

	out := make([]rawptr, len(lane), context.temp_allocator)
	for inst, i in lane {
		if inst.step.settings_size == 0 do continue
		buf: rawptr
		for a in active {
			for &o in a.v.overrides {
				if o.step != inst.step.name do continue
				src := _volume_override(a.v, &o, inst.step)
				if src == nil do continue
				if buf == nil {
					bytes, _ := runtime.mem_alloc_bytes(inst.step.settings_size, 16, context.temp_allocator)
					buf = raw_data(bytes)
					runtime.mem_copy(buf, inst.settings, inst.step.settings_size)
				}
				settings_blend(inst.step.settings_tid, buf, src, a.weight)
			}
		}
		out[i] = buf
	}
	return out
}

// An override's settings, typed: parsed when its text changed since the
// last time, kept per volume and step. nil (and one warning) when the text
// is not the step's settings.
@(private = "file")
_Override_Key :: struct {
	owner: Transform_Handle,
	step:  string, // the step's registered name, which lives as long as the registry
}

@(private = "file")
_Override_Cache :: struct {
	hash:  u64,
	buf:   []u8,
	valid: bool,
}

@(private = "file")
_override_cache: map[_Override_Key]_Override_Cache

@(private = "file")
_volume_override :: proc(v: ^Volume, o: ^Volume_Override, step: ^Render_Step) -> rawptr {
	context.allocator = runtime.default_allocator() // cross-frame state
	key := _Override_Key{Transform_Handle(v.owner), step.name}
	h := hash.fnv64a(transmute([]u8)o.settings)
	c, found := &_override_cache[key]
	if !found || c.hash != h || len(c.buf) != step.settings_size {
		if !found {
			_override_cache[key] = {}
			c = &_override_cache[key]
		}
		if len(c.buf) != step.settings_size {
			delete(c.buf)
			c.buf = make([]u8, step.settings_size)
		}
		c.hash = h
		c.valid = render_step_settings_parse(step, o.settings, c.buf)
		if !c.valid do log.warningf("[Render] a Volume's override of %q is not its settings (%v): ignored", step.name, step.settings_tid)
	}
	return c.valid ? raw_data(c.buf) : nil
}

// Forgets the parsed overrides (engine shutdown).
_render_volumes_shutdown :: proc() {
	for _, &c in _override_cache do delete(c.buf)
	delete(_override_cache)
	_override_cache = nil
}
