package audio_physics3d

// AudioOcclusion (plugins/audio/docs/components/AudioOcclusion.md): a wall
// between the listener and the AudioSource on this object muffles the source
// and turns it down. Each frame a ray goes from the listener to the source. A
// collider on `layers` in between, other than the source's own object and the
// listener's, blocks it. How blocked the source is moves toward the ray's
// answer at `speed`, so a sound going behind a wall fades rather than
// switches.

import "core:math/linalg"
import "moonhug:packages/engine"
import audio "moonhug:packages/audio"
import physics3d "moonhug:packages/physics3d"

@(component={menu="Audio/AudioOcclusion"})
@(typ_guid={guid="17b81d42-e588-4873-a078-b1629516489e"})
AudioOcclusion :: struct {
	using base: engine.CompData `inspect:"-"`,
	// Hz: a fully blocked source keeps what is below it.
	cutoff:     f32 `decor:range(10, 22000)`,
	// A fully blocked source's volume, as a part of its own.
	volume:     f32 `decor:range(0, 1)`,
	// The physics layers whose colliders block the sound.
	layers:     u32 `decor:layers(domain="physics3d")`,
	// How fast it follows a change: 1 takes a second from clear to blocked.
	speed:      f32 `decor:min(0.1)`,
	// How blocked the source is now, 0 to 1.
	amount:     f32 `json:"-" inspect:"-"`,
}

type_reset_AudioOcclusion :: proc(o: ^AudioOcclusion) {
	engine.comp_zero(o)
	o.cutoff = 800
	o.volume = 0.5
	o.layers = ~u32(0)
	o.speed = 6
}

@(late_update)
audio_occlusion_update :: proc(dt: f32) {
	w := engine.ctx_world()
	if w == nil do return
	pool := audio_occlusions(w)
	if pool == nil do return
	ear, _, ear_owner, has_ear := audio.audio_listener()
	it := engine.pool_iterator(pool)
	for o, _ in engine.pool_next(&it) {
		if !o.enabled || !engine.pool_valid(&w.transforms, engine.Handle(o.owner)) do continue
		_, src := engine.transform_get_comp(o.owner, audio.AudioSource)
		if src == nil do continue
		target: f32
		if has_ear && audio_occluded(ear, ear_owner, o.owner, o.layers) do target = 1
		step := o.speed * dt
		o.amount += clamp(target - o.amount, -step, step)
		src.occlusion = {amount = o.amount, cutoff = o.cutoff, volume = o.volume, frame = audio.audio_frame()}
	}
}

// Whether a collider on `layers` is between the listener at `ear` (its object
// `ear_owner`) and the object `source`. The two objects' own colliders, and
// those under them, never block.
audio_occluded :: proc(ear: [3]f32, ear_owner, source: engine.Transform_Handle, layers: u32) -> bool {
	to := engine.transform_world(source).position - ear
	dist := linalg.length(to)
	if dist < 0.01 do return false
	hit, ok := physics3d.raycast(ear, to, dist, layers, ignore = ear_owner)
	return ok && hit.object != source && !engine.transform_is_under(hit.object, source)
}
