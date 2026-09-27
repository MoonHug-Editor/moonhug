package animation_sequencer_tests

// Directors playing animation tracks (animation/sequencer).

import "core:testing"
import "moonhug:engine"
import anim "moonhug:packages/animation"
import seq "moonhug:packages/sequencer"
import common "moonhug:tests/common"
import anim_seq "moonhug:packages/animation/sequencer"

_clip_guid :: proc(n: u8) -> engine.Asset_GUID {
	id: engine.Asset_GUID
	id[15] = n
	id[0] = 0xAA
	return id
}

// A constant single-key clip: owner `prop` = `value` for its whole length.
_const_clip :: proc(path: anim.Animation_Path, value: [4]f32, length: f32 = 1, wrap: anim.Animation_Wrap = .Loop) -> anim.AnimationClip {
	clip := anim.AnimationClip{length = length, wrap = wrap}
	clip.channels = make([dynamic]anim.Animation_Channel)
	ch := anim.Animation_Channel{path = path}
	ch.times = make([dynamic]f32)
	ch.values = make([dynamic][4]f32)
	append(&ch.times, 0)
	append(&ch.values, value)
	append(&clip.channels, ch)
	return clip
}

// A two-key linear ramp clip: `prop` goes a -> b over `length`.
_ramp_clip :: proc(path: anim.Animation_Path, a, b: [4]f32, length: f32 = 1, wrap: anim.Animation_Wrap = .Once) -> anim.AnimationClip {
	clip := anim.AnimationClip{length = length, wrap = wrap}
	clip.channels = make([dynamic]anim.Animation_Channel)
	ch := anim.Animation_Channel{path = path}
	ch.times = make([dynamic]f32)
	ch.values = make([dynamic][4]f32)
	append(&ch.times, 0, length)
	append(&ch.values, a, b)
	append(&clip.channels, ch)
	return clip
}

// Build a track NODE with clip NODES under `owner` — what the window's Add
// Track/Add Clip produce. Reuses the view struct as the clip parameter.
_mk_track :: proc(owner: engine.Transform_Handle, kind: engine.TypeKey, clips: ..seq.Clip_View) -> engine.Transform_Handle {
	desc, _ := seq.track_desc(kind)
	node := engine.transform_new(desc.label, owner)
	engine.transform_get_or_add_comp(node, seq.TimelineTrack)
	engine.transform_add_comp(node, kind)
	for c in clips {
		cn := engine.transform_new(len(c.name) > 0 ? c.name : "clip", node)
		_, cc := engine.transform_get_or_add_comp(cn, seq.TimelineClip)
		cc.start = c.start
		cc.duration = c.duration
		cc.ease_in = c.ease_in
		cc.ease_out = c.ease_out
		cc.speed = c.speed
		if desc.clip_key != engine.INVALID_TYPE_KEY do engine.transform_add_comp(cn, desc.clip_key)
	}
	return node
}

// Point an activation track at a transform.
_set_activation_target :: proc(node: engine.Transform_Handle, target: engine.Ref_Local) {
	if _, at := seq.get_comp(node, seq.TrackActivation); at != nil do at.target = target
}

// Set an animation clip's .anim.
_set_anim_clip :: proc(track_node: engine.Transform_Handle, index: int, guid: engine.Asset_GUID) {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(track_node))
	if t == nil || index >= len(t.children) do return
	cn := engine.Transform_Handle(t.children[index].handle)
	if _, cr := anim.get_comp(cn, anim_seq.ClipAnimation); cr != nil do cr.clip = guid
}

@(test)
test_director_playback :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	seq.register_builtin_tracks()
	anim_seq.animation_track_init()

	// Clips: a ramp x 0->10 over 1s, and a constant x=4.
	ramp_guid, const_guid := _clip_guid(10), _clip_guid(11)
	anim.animation_clip_cache[ramp_guid] = _ramp_clip(.Position, {0, 0, 0, 0}, {10, 0, 0, 0})
	anim.animation_clip_cache[const_guid] = _const_clip(.Position, {4, 0, 0, 0})

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	child := engine.transform_new("Child", root)

	_, raw := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^seq.PlayableDirector)raw
	d.enabled = true
	d.duration = 2
	defer seq.director_teardown(d)

	// Timeline subtree: anim clip A [0,1), anim clip B [1,2), an activation
	// span [0.5, 1.5) on the child. Loops at duration 2.
	at := _mk_track(root, .TrackAnimation,
		seq.Clip_View{start = 0, duration = 1},
		seq.Clip_View{start = 1, duration = 1},
	)
	_set_anim_clip(at, 0, ramp_guid)
	_set_anim_clip(at, 1, const_guid)
	act := _mk_track(root, .TrackActivation, seq.Clip_View{start = 0.5, duration = 1})
	_set_activation_target(act, {handle = engine.Handle(child)})
	// t = 0.5: ramp samples 5, activation just began.
	for _ in 0 ..< 5 do seq.director_tick(d, 0.1)
	rt := engine.pool_get(&tc.world.transforms, engine.Handle(root))
	ct := engine.pool_get(&tc.world.transforms, engine.Handle(child))
	testing.expect(t, abs(rt.position.x - 5) < 0.11, "animation track must drive the pose")
	testing.expect(t, ct.is_active, "activation span must activate the child")

	// t = 1.5: clip B active (x = 4), activation span ended.
	for _ in 0 ..< 10 do seq.director_tick(d, 0.1)
	testing.expect(t, abs(rt.position.x - 4) < 0.001, "second clip must take over")
	testing.expect(t, !ct.is_active, "activation must end outside its span")
}

@(test)
test_director_control_and_scrub :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	seq.register_builtin_tracks()
	anim_seq.animation_track_init()

	ramp_guid := _clip_guid(12)
	anim.animation_clip_cache[ramp_guid] = _ramp_clip(.Position, {0, 0, 0, 0}, {10, 0, 0, 0})

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	_, raw := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^seq.PlayableDirector)raw
	d.enabled = true
	d.duration = 1
	d.wrap = .Once
	d.manual_start = true
	defer seq.director_teardown(d)

	at := _mk_track(root, .TrackAnimation, seq.Clip_View{start = 0, duration = 1})
	_set_anim_clip(at, 0, ramp_guid)

	// Manual start holds playback until director_play.
	for _ in 0 ..< 3 do seq.director_tick(d, 0.1)
	testing.expect_value(t, d.time, 0)
	seq.director_play(d)
	for _ in 0 ..< 3 do seq.director_tick(d, 0.1)
	testing.expect(t, d.time > 0.29, "play must start advancing")

	// Once: clamps at the duration and stops.
	for _ in 0 ..< 20 do seq.director_tick(d, 0.1)
	testing.expect_value(t, d.time, 1)
	testing.expect(t, !d.playing, "Once must stop at the end")

	// Scrub: jump to 0.3 evaluates the pose.
	seq.director_set_time(d, 0.3)
	rt := engine.pool_get(&tc.world.transforms, engine.Handle(root))
	testing.expect(t, abs(rt.position.x - 3) < 0.001, "scrub must evaluate the pose at the set time")
}

// Control track: a clip node hosting a nested timeline (a child node with
// its own PlayableDirector) plays it at the clip-local time with the
// parent's mode. Outside the span the child rests at 0. The nested director
// never self-ticks — the parent owns its time.
@(test)
test_control_track_drives_nested_director :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	seq.register_builtin_tracks()
	anim_seq.animation_track_init()

	ramp_guid := _clip_guid(13)
	anim.animation_clip_cache[ramp_guid] = _ramp_clip(.Position, {0, 0, 0, 0}, {10, 0, 0, 0})

	root := engine.transform_new("Host")
	engine.scene_set_root(tc.scene, root)
	_, raw := engine.transform_add_comp(root, .PlayableDirector)
	host := cast(^seq.PlayableDirector)raw
	host.enabled = true
	host.duration = 3
	host.wrap = .Once
	defer seq.director_teardown(host)

	// Control track with a clip [1, 2); under the clip node, a nested
	// timeline: its own director + an animation track ramping x over 1s.
	ctrl := _mk_track(root, .TrackControl, seq.Clip_View{start = 1, duration = 1})
	clip_node: engine.Transform_Handle
	{
		w := engine.ctx_world()
		tn := engine.pool_get(&w.transforms, engine.Handle(ctrl))
		clip_node = engine.Transform_Handle(tn.children[0].handle)
	}
	nested_root := engine.transform_new("Nested", clip_node)
	_, nraw := engine.transform_add_comp(nested_root, .PlayableDirector)
	nested := cast(^seq.PlayableDirector)nraw
	nested.enabled = true
	nested.duration = 1
	nested.manual_start = true
	defer seq.director_teardown(nested)
	nat := _mk_track(nested_root, .TrackAnimation, seq.Clip_View{start = 0, duration = 1})
	_set_anim_clip(nat, 0, ramp_guid)

	nt := engine.pool_get(&tc.world.transforms, engine.Handle(nested_root))

	// Before the span: the nested timeline rests at 0.
	for _ in 0 ..< 5 do seq.director_tick(host, 0.1) // t = 0.5
	testing.expect(t, abs(nt.position.x - 0) < 0.001, "nested rests at 0 before the span")

	// Inside the span: clip-local time drives the nested ramp.
	for _ in 0 ..< 10 do seq.director_tick(host, 0.1) // t = 1.5 -> local 0.5
	testing.expect(t, abs(nt.position.x - 5) < 0.11, "nested plays at the clip-local time")

	// After the span: back to rest.
	for _ in 0 ..< 10 do seq.director_tick(host, 0.1) // t = 2.5
	testing.expect(t, abs(nt.position.x - 0) < 0.001, "nested rests after the span")

	// Scrubbing the host scrubs the nested timeline the same way.
	seq.director_set_time(host, 1.8)
	testing.expect(t, abs(nt.position.x - 8) < 0.11, "host scrub reaches the nested timeline")
}

// An animation track drives an ANIMATION COMPONENT (Unity's model: the
// timeline takes over the Animator). Its target names which one; unset, it
// finds one on the director, and poses the director's transform directly
// when there is none. The driven component's own playback stands down, so
// the two never write the same transforms in one frame.
@(test)
test_animation_track_target :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	seq.register_builtin_tracks()
	anim_seq.animation_track_init()

	ramp_guid := _clip_guid(20)
	anim.animation_clip_cache[ramp_guid] = _ramp_clip(.Position, {0, 0, 0, 0}, {10, 0, 0, 0})

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	actor := engine.transform_new("Actor", root)

	_, raw := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^seq.PlayableDirector)raw
	d.enabled = true
	d.duration = 1
	d.wrap = .Once
	defer seq.director_teardown(d)

	at := _mk_track(root, .TrackAnimation, seq.Clip_View{start = 0, duration = 1})
	_set_anim_clip(at, 0, ramp_guid)

	rt := engine.pool_get(&tc.world.transforms, engine.Handle(root))
	act := engine.pool_get(&tc.world.transforms, engine.Handle(actor))

	// No target: the director itself animates (the default).
	seq.director_set_time(d, 0.5)
	testing.expect(t, abs(rt.position.x - 5) < 0.001, "an untargeted track animates the director")
	testing.expect(t, abs(act.position.x - 0) < 0.001, "the other object is untouched")

	// Point it at an Animation ON the actor: the clip now plays there, and
	// the director's pose is released rather than left frozen mid-animation.
	a_owned, a_comp := engine.transform_add_comp(actor, .Animation)
	acomp := cast(^anim.Animation)a_comp
	acomp.enabled = true
	acomp.play_automatically = true
	acomp.clip = ramp_guid
	if _, atc := anim.get_comp(at, anim_seq.TrackAnimation); atc != nil {
		atc.target = {handle = a_owned.handle}
	}
	seq.director_set_time(d, 0.5)
	testing.expect(t, abs(act.position.x - 5) < 0.001, "the track animates its target's object")
	testing.expect(t, abs(rt.position.x - 0) < 0.001, "retargeting releases the previous object")

	// While driven, the component's own playback stands down — its tick must
	// not also write the object (last-writer-wins was the whole hazard).
	testing.expect(t, acomp.timeline_driven, "the driven component is suppressed")
	anim.animation_tick(0.5)
	testing.expect(t, abs(act.position.x - 5) < 0.001,
		"the suppressed component does not fight the track")

	// The preview ending hands the object back.
	seq.director_preview_end(d)
	testing.expect(t, !acomp.timeline_driven, "preview end releases the component")
}

// Two animation tracks on one object, both animating the same channel, the
// second easing in over the first.
//
// One output and one layer mixer means the second track blends over whatever
// the first produced THIS evaluation. With a graph each, the second resolved
// its partial weight against its own bind-time default — captured once, on the
// first evaluation, and never refreshed. The two agree on frame one and
// diverge as soon as the first track's value moves, which is the drift the
// pure-evaluator rule exists to prevent.
@(test)
test_two_animation_tracks_blend_on_one_object :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	anim_seq.animation_track_init()

	ramp_guid, hi_guid := _clip_guid(21), _clip_guid(22)
	anim.animation_clip_cache[ramp_guid] = _ramp_clip(.Position, {0, 0, 0, 0}, {10, 0, 0, 0})
	anim.animation_clip_cache[hi_guid] = _ramp_clip(.Position, {20, 0, 0, 0}, {20, 0, 0, 0})

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)

	_, raw := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^seq.PlayableDirector)raw
	d.enabled = true
	d.duration = 1
	d.wrap = .Once
	defer seq.director_teardown(d)

	a := _mk_track(root, .TrackAnimation, seq.Clip_View{start = 0, duration = 1})
	_set_anim_clip(a, 0, ramp_guid)
	// ease_in 1 makes this track's weight equal to the timeline time.
	b := _mk_track(root, .TrackAnimation, seq.Clip_View{start = 0, duration = 1, ease_in = 1})
	_set_anim_clip(b, 0, hi_guid)

	rt := engine.pool_get(&tc.world.transforms, engine.Handle(root))

	// Frame one: A is at 2.5, B blends in at 0.25 -> lerp(2.5, 20, 0.25).
	seq.director_set_time(d, 0.25)
	testing.expect(t, abs(rt.position.x - 6.875) < 0.001,
		"the later track blends over the earlier one")

	// Frame two: A has moved to 7.5, so B must blend over 7.5, not over a
	// default captured on frame one -> lerp(7.5, 20, 0.75).
	seq.director_set_time(d, 0.75)
	testing.expect(t, abs(rt.position.x - 16.875) < 0.001,
		"the blend follows the earlier track instead of a stale default")
}
