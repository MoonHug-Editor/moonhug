package sequencer_tests

// PlayableDirector on the timeline-as-prefab model: the timeline IS the
// director's subtree — track nodes as children, clip nodes under them.
// Headless coverage: playback across kinds, manual start, Once/Loop, scrub
// silence, target round trip through Simulate's snapshot/restore, the
// activation preview restore, and the control track driving a nested
// director.

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
_mk_track :: proc(owner: engine.Transform_Handle, kind: string, target: engine.Ref_Local = {}, clips: ..seq.Timeline_Clip) -> engine.Transform_Handle {
	node := engine.transform_new(kind, owner)
	_, tc := engine.transform_get_or_add_comp(node, seq.TimelineTrack)
	tc.kind = strings.clone(kind)
	tc.target = target
	for c in clips {
		cn := engine.transform_new(len(c.name) > 0 ? c.name : "clip", node)
		_, cc := engine.transform_get_or_add_comp(cn, seq.TimelineClip)
		cc.start = c.start
		cc.duration = c.duration
		cc.ease_in = c.ease_in
		cc.ease_out = c.ease_out
		cc.speed = c.speed
		cc.asset = c.asset
	}
	return node
}

_marker_hits: int
_count_marker :: proc(name: string, target: engine.Ref_Local) {
	if name == "hit" do _marker_hits += 1
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
	// span [0.5, 1.5) on the child, a marker at 0.5. Loops at duration 2.
	_mk_track(root, "animation", {},
		seq.Timeline_Clip{start = 0, duration = 1, asset = ramp_guid},
		seq.Timeline_Clip{start = 1, duration = 1, asset = const_guid},
	)
	_mk_track(root, "activation", {handle = engine.Handle(child)},
		seq.Timeline_Clip{start = 0.5, duration = 1})
	_mk_track(root, "marker", {}, seq.Timeline_Clip{start = 0.5, name = "hit"})

	_marker_hits = 0
	seq.timeline_marker_hook = _count_marker
	defer seq.timeline_marker_hook = nil

	// t = 0.5: ramp samples 5, activation just began, marker crossed once.
	for _ in 0 ..< 5 do seq.director_tick(d, 0.1)
	rt := engine.pool_get(&tc.world.transforms, engine.Handle(root))
	ct := engine.pool_get(&tc.world.transforms, engine.Handle(child))
	testing.expect(t, abs(rt.position.x - 5) < 0.11, "animation track must drive the pose")
	testing.expect(t, ct.is_active, "activation span must activate the child")

	// t = 1.5: clip B active (x = 4), activation span ended, the marker's
	// [0.5, 0.6) window was crossed once on the way.
	for _ in 0 ..< 10 do seq.director_tick(d, 0.1)
	testing.expect(t, abs(rt.position.x - 4) < 0.001, "second clip must take over")
	testing.expect(t, !ct.is_active, "activation must end outside its span")
	testing.expect_value(t, _marker_hits, 1)

	// Loop wrap: after another full cycle the marker fired again.
	for _ in 0 ..< 20 do seq.director_tick(d, 0.1)
	testing.expect_value(t, _marker_hits, 2)
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

	_mk_track(root, "animation", {}, seq.Timeline_Clip{start = 0, duration = 1, asset = ramp_guid})
	_mk_track(root, "marker", {}, seq.Timeline_Clip{start = 0.5, name = "hit"})

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

	// Scrub: jump to 0.3 evaluates the pose, markers stay silent.
	_marker_hits = 0
	seq.timeline_marker_hook = _count_marker
	defer seq.timeline_marker_hook = nil
	seq.director_set_time(d, 0.3)
	rt := engine.pool_get(&tc.world.transforms, engine.Handle(root))
	testing.expect(t, abs(rt.position.x - 3) < 0.001, "scrub must evaluate the pose at the set time")
	seq.director_set_time(d, 0.7)
	testing.expect_value(t, _marker_hits, 0)
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
	_mk_track(root, "activation",
		{local_id = ct.local_id, handle = engine.Handle(child)},
		seq.Timeline_Clip{start = 0, duration = 1})
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
	testing.expect_value(t, tracks[0].target.local_id, want_lid)
	testing.expect(t, engine.world_pool_valid(&tc.world, tracks[0].target.handle),
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

	_mk_track(root, "activation", {handle = engine.Handle(child)},
		seq.Timeline_Clip{start = 0, duration = 1})

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
	ctrl := _mk_track(root, "control", {}, seq.Timeline_Clip{start = 1, duration = 1})
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
	_mk_track(nested_root, "animation", {}, seq.Timeline_Clip{start = 0, duration = 1, asset = ramp_guid})

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
