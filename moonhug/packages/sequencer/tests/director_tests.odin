package sequencer_tests

// PlayableDirector: timeline playback headless — animation track crossfades
// through the graph, activation spans, marker crossings (with loop wrap),
// manual start, Once stop, and the scrub path.

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

_tl_guid :: proc(n: u8) -> engine.Asset_GUID {
	id: engine.Asset_GUID
	id[15] = n
	id[0] = 0xBB
	return id
}

@(private = "file")
_track :: proc(kind: string, clips: ..seq.Timeline_Clip) -> seq.Timeline_Track {
	t := seq.Timeline_Track{kind = strings.clone(kind), name = strings.clone(kind)}
	t.clips = make([dynamic]seq.Timeline_Clip)
	for c in clips {
		cc := c
		cc.name = strings.clone(c.name)
		append(&t.clips, cc)
	}
	return t
}

@(private = "file") _marker_hits: int

@(private = "file")
_count_marker :: proc(name: string, target: engine.Ref_Local) {
	_marker_hits += 1
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
	seq.timeline_cache_init()
	defer seq.timeline_cache_shutdown()
	seq.register_builtin_tracks()
	anim.animation_track_init()

	// Clips: a ramp x 0->10 over 1s, and a constant x=4.
	ramp_guid, const_guid := _clip_guid(10), _clip_guid(11)
	anim.animation_clip_cache[ramp_guid] = _ramp_clip(.Position, {0, 0, 0, 0}, {10, 0, 0, 0})
	anim.animation_clip_cache[const_guid] = _const_clip(.Position, {4, 0, 0, 0})

	// Timeline: anim clip A [0,1), anim clip B [1,2), an activation span
	// [0.5, 1.5) on a child, a marker at 0.5. Loops at duration 2.
	tl := seq.Timeline{duration = 2}
	tl.tracks = make([dynamic]seq.Timeline_Track)
	append(&tl.tracks, _track("animation",
		seq.Timeline_Clip{start = 0, duration = 1, asset = ramp_guid},
		seq.Timeline_Clip{start = 1, duration = 1, asset = const_guid},
	))
	append(&tl.tracks, _track("activation", seq.Timeline_Clip{start = 0.5, duration = 1}))
	append(&tl.tracks, _track("marker", seq.Timeline_Clip{start = 0.5, name = "hit"}))
	guid := _tl_guid(1)
	seq.timeline_cache[guid] = tl

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	child := engine.transform_new("Child", root)

	_, raw := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^seq.PlayableDirector)raw
	d.enabled = true
	d.timeline = {guid = guid}
	append(&d.bindings, seq.Track_Binding{track = 1, target = {handle = engine.Handle(child)}})

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
	seq.timeline_cache_init()
	defer seq.timeline_cache_shutdown()
	seq.register_builtin_tracks()
	anim.animation_track_init()

	ramp_guid := _clip_guid(12)
	anim.animation_clip_cache[ramp_guid] = _ramp_clip(.Position, {0, 0, 0, 0}, {10, 0, 0, 0})
	tl := seq.Timeline{duration = 1}
	tl.tracks = make([dynamic]seq.Timeline_Track)
	append(&tl.tracks, _track("animation", seq.Timeline_Clip{start = 0, duration = 1, asset = ramp_guid}))
	append(&tl.tracks, _track("marker", seq.Timeline_Clip{start = 0.5, name = "hit"}))
	guid := _tl_guid(2)
	seq.timeline_cache[guid] = tl

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	_, raw := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^seq.PlayableDirector)raw
	d.enabled = true
	d.timeline = {guid = guid}
	d.wrap = .Once
	d.manual_start = true

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
