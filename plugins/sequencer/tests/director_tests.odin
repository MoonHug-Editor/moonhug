package sequencer_tests

// PlayableDirector on the timeline-as-prefab model: the timeline IS the
// director's subtree — track nodes as children, clip nodes under them.
// Headless coverage: playback across kinds, manual start, Once/Loop, scrub
// silence, target round trip through Simulate's snapshot/restore, the
// activation preview restore, and the control track driving a nested
// director.

import "core:os"
import "core:strings"
import "core:testing"
import "moonhug:engine"
import anim "moonhug:packages/animation"
import seq "moonhug:packages/sequencer"
import common "moonhug:tests/common"

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
	if _, cr := anim.get_comp(cn, anim.ClipAnimation); cr != nil do cr.clip = guid
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
	anim.animation_track_init()

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
	anim.animation_track_init()

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

// A track's target must survive the Simulate round trip (serialize the
// scene, reload it in place — what Play/Stop does). The target is an
// ordinary component field now, so this covers the whole timeline subtree.
@(test)
test_track_target_survives_serialize_roundtrip :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	seq.register_builtin_tracks()

	root := engine.transform_new("Stage")
	engine.scene_set_root(tc.scene, root)
	child := engine.transform_new("Target", root)

	_, draw_ := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^seq.PlayableDirector)draw_
	d.enabled = true

	ct := engine.pool_get(&tc.world.transforms, engine.Handle(child))
	testing.expect(t, ct != nil)
	if ct == nil do return
	act := _mk_track(root, .TrackActivation, seq.Clip_View{start = 0, duration = 1})
	_set_activation_target(act, {local_id = ct.local_id, handle = engine.Handle(child)})
	want_lid := ct.local_id
	testing.expect(t, want_lid != 0, "the target must have a local id")

	bytes, ok := engine.scene_serialize(tc.scene)
	testing.expect(t, ok, "snapshot should capture")
	if !ok do return
	defer delete(bytes)
	reloaded := engine.scene_reload_in_place_bytes(tc.scene, bytes)
	testing.expect(t, reloaded != nil, "restore should load")
	if reloaded == nil do return
	tc.scene = reloaded

	d2: ^seq.PlayableDirector
	{
		it := engine.pool_iterator(seq.playable_directors(&tc.world))
		for dd, _ in engine.pool_next(&it) do d2 = dd
	}
	testing.expect(t, d2 != nil, "director survives the round trip")
	if d2 == nil do return
	tracks := seq.director_tracks(d2)
	testing.expect_value(t, len(tracks), 1)
	if len(tracks) != 1 do return
	_, at2 := seq.get_comp(tracks[0].node, seq.TrackActivation)
	testing.expect(t, at2 != nil, "the kind component survives")
	if at2 == nil do return
	testing.expect_value(t, at2.target.local_id, want_lid)
	testing.expect(t, engine.world_pool_valid(&tc.world, at2.target.handle),
		"the target handle must re-resolve after restore")
	testing.expect_value(t, len(tracks[0].clips), 1)
}

// The activation track owns its preview restore: outside Play mode the tick
// captures the pre-tick is_active and preview_end writes it back — including
// an authored-INACTIVE object.
@(test)
test_activation_preview_restores_authored_state :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	seq.register_builtin_tracks()

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	child := engine.transform_new("Child", root)

	_, raw := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^seq.PlayableDirector)raw
	d.enabled = true
	d.duration = 2
	defer seq.director_teardown(d)

	act := _mk_track(root, .TrackActivation, seq.Clip_View{start = 0, duration = 1})
	_set_activation_target(act, {handle = engine.Handle(child)})

	ct := engine.pool_get(&tc.world.transforms, engine.Handle(child))
	ct.is_active = false // authored INACTIVE

	// One preview frame: scrub inside the span activates, restore un-does it.
	seq.director_set_time(d, 0.5)
	testing.expect(t, ct.is_active, "the span activates the target during preview")
	seq.director_preview_end(d)
	testing.expect(t, !ct.is_active, "preview restore returns the AUTHORED state, not true")

	// Same through the preview-play per-frame bracket.
	seq.director_preview_step(d, 0.4)
	seq.director_preview_end(d, playing = true)
	testing.expect(t, !ct.is_active, "per-frame restore while playing also returns authored state")

	// The runtime path never captures — play mode leaves the tick's result.
	ct.is_active = true
	seq.director_tick(d, 0.5)
	testing.expect(t, ct.is_active, "runtime play drives activation directly")
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
	anim.animation_track_init()

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

// Overlap IS the blend (Unity's Timeline model): where two clips on a track
// overlap, the earlier ramps out across the overlap while the later ramps
// in, with no authoring. Explicit eases still apply at boundaries with no
// neighbour. Derived from the spans, so it can never disagree with them.
@(test)
test_clip_weight_overlap_crossfades :: proc(t: ^testing.T) {
	// A [0,2), B [1,3) — a 1s overlap in [1,2).
	clips := []seq.Clip_View{
		{start = 0, duration = 2},
		{start = 1, duration = 2},
	}

	// Outside the overlap both sit at full weight.
	testing.expect(t, seq.track_clip_weight(clips, 0, 0.5) == 1, "A is full before the overlap")
	testing.expect(t, seq.track_clip_weight(clips, 1, 2.5) == 1, "B is full after the overlap")

	// Mid-overlap they meet at 0.5 — a symmetric crossfade.
	a_mid := seq.track_clip_weight(clips, 0, 1.5)
	b_mid := seq.track_clip_weight(clips, 1, 1.5)
	testing.expect(t, abs(a_mid - 0.5) < 0.001, "A is half way out at the overlap centre")
	testing.expect(t, abs(b_mid - 0.5) < 0.001, "B is half way in at the overlap centre")

	// The pair sums to 1 across the whole overlap: no dip, no double.
	for i in 0 ..= 10 {
		time := 1 + f32(i) / 10 * 0.999
		sum := seq.track_clip_weight(clips, 0, time) + seq.track_clip_weight(clips, 1, time)
		testing.expectf(t, abs(sum - 1) < 0.001, "weights must sum to 1 at t=%.2f, got %.3f", time, sum)
	}

	// Outside every span: nothing.
	testing.expect(t, seq.track_clip_weight(clips, 0, 2.5) == 0, "A is silent past its end")
	testing.expect(t, seq.track_clip_weight(clips, 1, 0.5) == 0, "B is silent before its start")
}

// An explicit ease with no neighbour still ramps, and an overlap wider than
// the authored ease wins (the clips actually overlap that much).
@(test)
test_clip_weight_explicit_ease :: proc(t: ^testing.T) {
	solo := []seq.Clip_View{{start = 0, duration = 2, ease_in = 1, ease_out = 0.5}}
	testing.expect(t, abs(seq.track_clip_weight(solo, 0, 0.5) - 0.5) < 0.001, "ease_in ramps up")
	testing.expect(t, seq.track_clip_weight(solo, 0, 1.2) == 1, "full weight between the ramps")
	testing.expect(t, abs(seq.track_clip_weight(solo, 0, 1.75) - 0.5) < 0.001, "ease_out ramps down")

	// A 1s overlap beats a 0.2s authored ease_in on the later clip.
	pair := []seq.Clip_View{
		{start = 0, duration = 2},
		{start = 1, duration = 2, ease_in = 0.2},
	}
	testing.expect(t, abs(seq.track_clip_weight(pair, 1, 1.5) - 0.5) < 0.001,
		"the overlap drives the blend, not the smaller authored ease")
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
	anim.animation_track_init()

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
	if _, atc := anim.get_comp(at, anim.TrackAnimation); atc != nil {
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

// CROSS-BOUNDARY TARGETS: a timeline PREFAB instanced into a host scene,
// with its track bound to a HOST-SCENE object. This is what makes a timeline
// reusable — the prefab knows nothing about the host, the instance binds it,
// and the binding persists as an ordinary prefab OVERRIDE.
//
// The binding must be recorded, not just assigned: the inspector records at
// every field commit, and a bare mutation on nested content is not saved.
@(test)
test_timeline_prefab_instance_targets_host_object :: proc(t: ^testing.T) {
	dir := "moonhug/tests/_test_tl_xboundary"
	os.make_directory(dir)
	tl_path := strings.concatenate({dir, "/tl.scene"}, context.temp_allocator)
	defer {
		os.remove(tl_path)
		os.remove(strings.concatenate({tl_path, ".meta"}, context.temp_allocator))
		os.remove(dir)
	}

	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	seq.register_builtin_tracks()

	// Author a timeline prefab with an UNBOUND activation track.
	root := engine.transform_new("TL")
	engine.scene_set_root(tc.scene, root)
	_, raw := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^seq.PlayableDirector)raw
	d.enabled = true
	d.duration = 2
	_mk_track(root, .TrackActivation, seq.Clip_View{start = 0, duration = 1})
	testing.expect(t, engine.scene_save(tc.scene, tl_path), "prefab saved")

	engine.asset_db_init(dir)
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()
	tl_guid, gok := engine.asset_db_get_guid(tl_path)
	testing.expect(t, gok, "prefab registered")
	if !gok do return

	// Host scene with an actor and an instance of the prefab.
	host := engine.scene_load_single_path(tl_path)
	testing.expect(t, host != nil)
	if host == nil do return
	tc.scene = host
	hroot := engine.Transform_Handle(host.root.handle)
	actor := engine.transform_new("Actor", hroot)
	aT := engine.pool_get(&tc.world.transforms, engine.Handle(actor))

	inst := engine.scene_instantiate_guid_nested(engine.Asset_GUID(tl_guid), hroot)
	testing.expect(t, inst != {}, "prefab instantiates")
	if inst == {} do return

	// The instance's track, bound to the HOST's actor and RECORDED.
	track: engine.Transform_Handle
	{
		it := engine.pool_iterator(&tc.world.transforms)
		for _, h in engine.pool_next(&it) {
			hh := h
			hh.type_key = .Transform
			if _, a := seq.get_comp(engine.Transform_Handle(hh), seq.TrackActivation); a != nil {
				track = engine.Transform_Handle(hh)
			}
		}
	}
	testing.expect(t, track != {}, "the instance has the activation track")
	if track == {} do return
	owned, act := seq.get_comp(track, seq.TrackActivation)
	act.target = {local_id = aT.local_id, handle = engine.Handle(actor)}
	_, rok := engine.nested_scene_record_override_for_host(
		host, inst, owned.local_id, "target", &act.target, typeid_of(engine.Ref_Local))
	testing.expect(t, rok, "the host binding records as a prefab override")

	// It drives the host object.
	di: ^seq.PlayableDirector
	{
		it := engine.pool_iterator(seq.playable_directors(&tc.world))
		for dd, _ in engine.pool_next(&it) do di = dd
	}
	testing.expect(t, di != nil)
	if di == nil do return
	defer seq.director_teardown(di)
	aT.is_active = false
	seq.director_set_time(di, 0.5)
	testing.expect(t, aT.is_active, "the instance's track drives the HOST object")

	// And survives the Play/Stop round trip.
	bytes, ok := engine.scene_serialize(tc.scene)
	testing.expect(t, ok)
	if !ok do return
	defer delete(bytes)
	reloaded := engine.scene_reload_in_place_bytes(tc.scene, bytes)
	testing.expect(t, reloaded != nil)
	if reloaded == nil do return
	tc.scene = reloaded

	found := false
	{
		it := engine.pool_iterator(&tc.world.transforms)
		for _, h in engine.pool_next(&it) {
			hh := h
			hh.type_key = .Transform
			if _, a := seq.get_comp(engine.Transform_Handle(hh), seq.TrackActivation); a != nil {
				found = true
				testing.expect(t, a.target.local_id != 0, "the host binding survived reload")
				testing.expect(t, engine.world_pool_valid(&tc.world, a.target.handle),
					"and re-resolves to a live host object")
			}
		}
	}
	testing.expect(t, found, "the instance survives reload")
}
