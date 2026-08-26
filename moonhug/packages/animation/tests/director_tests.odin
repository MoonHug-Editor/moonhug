package animation_tests

// PlayableDirector: timeline playback headless — animation track crossfades
// through the graph, activation spans, marker crossings (with loop wrap),
// manual start, Once stop, and the scrub path.

import "core:strings"
import "core:testing"
import "moonhug:engine"
import anim "moonhug:packages/animation"
import common "moonhug:tests/common"

_tl_guid :: proc(n: u8) -> engine.Asset_GUID {
	id: engine.Asset_GUID
	id[15] = n
	id[0] = 0xBB
	return id
}

@(private = "file")
_track :: proc(kind: string, clips: ..anim.Timeline_Clip) -> anim.Timeline_Track {
	t := anim.Timeline_Track{kind = strings.clone(kind), name = strings.clone(kind)}
	t.clips = make([dynamic]anim.Timeline_Clip)
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
	anim.timeline_cache_init()
	defer anim.timeline_cache_shutdown()
	anim.register_builtin_tracks()

	// Clips: a ramp x 0->10 over 1s, and a constant x=4.
	ramp_guid, const_guid := _clip_guid(10), _clip_guid(11)
	anim.animation_clip_cache[ramp_guid] = _ramp_clip(.Position, {0, 0, 0, 0}, {10, 0, 0, 0})
	anim.animation_clip_cache[const_guid] = _const_clip(.Position, {4, 0, 0, 0})

	// Timeline: anim clip A [0,1), anim clip B [1,2), an activation span
	// [0.5, 1.5) on a child, a marker at 0.5. Loops at duration 2.
	tl := anim.Timeline{duration = 2}
	tl.tracks = make([dynamic]anim.Timeline_Track)
	append(&tl.tracks, _track("animation",
		anim.Timeline_Clip{start = 0, duration = 1, asset = ramp_guid},
		anim.Timeline_Clip{start = 1, duration = 1, asset = const_guid},
	))
	append(&tl.tracks, _track("activation", anim.Timeline_Clip{start = 0.5, duration = 1}))
	append(&tl.tracks, _track("marker", anim.Timeline_Clip{start = 0.5, name = "hit"}))
	guid := _tl_guid(1)
	anim.timeline_cache[guid] = tl

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	child := engine.transform_new("Child", root)

	_, raw := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^anim.PlayableDirector)raw
	d.enabled = true
	d.timeline = {guid = guid}
	append(&d.bindings, anim.Track_Binding{track = 1, target = {handle = engine.Handle(child)}})

	_marker_hits = 0
	anim.timeline_marker_hook = _count_marker
	defer anim.timeline_marker_hook = nil

	// t = 0.5: ramp samples 5, activation just began, marker crossed once.
	for _ in 0 ..< 5 do anim.director_tick(d, 0.1)
	rt := engine.pool_get(&tc.world.transforms, engine.Handle(root))
	ct := engine.pool_get(&tc.world.transforms, engine.Handle(child))
	testing.expect(t, abs(rt.position.x - 5) < 0.11, "animation track must drive the pose")
	testing.expect(t, ct.is_active, "activation span must activate the child")

	// t = 1.5: clip B active (x = 4), activation span ended, the marker's
	// [0.5, 0.6) window was crossed once on the way.
	for _ in 0 ..< 10 do anim.director_tick(d, 0.1)
	testing.expect(t, abs(rt.position.x - 4) < 0.001, "second clip must take over")
	testing.expect(t, !ct.is_active, "activation must end outside its span")
	testing.expect_value(t, _marker_hits, 1)

	// Loop wrap: after another full cycle the marker fired again.
	for _ in 0 ..< 20 do anim.director_tick(d, 0.1)
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
	anim.timeline_cache_init()
	defer anim.timeline_cache_shutdown()
	anim.register_builtin_tracks()

	ramp_guid := _clip_guid(12)
	anim.animation_clip_cache[ramp_guid] = _ramp_clip(.Position, {0, 0, 0, 0}, {10, 0, 0, 0})
	tl := anim.Timeline{duration = 1}
	tl.tracks = make([dynamic]anim.Timeline_Track)
	append(&tl.tracks, _track("animation", anim.Timeline_Clip{start = 0, duration = 1, asset = ramp_guid}))
	append(&tl.tracks, _track("marker", anim.Timeline_Clip{start = 0.5, name = "hit"}))
	guid := _tl_guid(2)
	anim.timeline_cache[guid] = tl

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	_, raw := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^anim.PlayableDirector)raw
	d.enabled = true
	d.timeline = {guid = guid}
	d.wrap = .Once
	d.manual_start = true

	// Manual start holds playback until director_play.
	for _ in 0 ..< 3 do anim.director_tick(d, 0.1)
	testing.expect_value(t, d.time, 0)
	anim.director_play(d)
	for _ in 0 ..< 3 do anim.director_tick(d, 0.1)
	testing.expect(t, d.time > 0.29, "play must start advancing")

	// Once: clamps at the duration and stops.
	for _ in 0 ..< 20 do anim.director_tick(d, 0.1)
	testing.expect_value(t, d.time, 1)
	testing.expect(t, !d.playing, "Once must stop at the end")

	// Scrub: jump to 0.3 evaluates the pose, markers stay silent.
	_marker_hits = 0
	anim.timeline_marker_hook = _count_marker
	defer anim.timeline_marker_hook = nil
	anim.director_set_time(d, 0.3)
	rt := engine.pool_get(&tc.world.transforms, engine.Handle(root))
	testing.expect(t, abs(rt.position.x - 3) < 0.001, "scrub must evaluate the pose at the set time")
	anim.director_set_time(d, 0.7)
	testing.expect_value(t, _marker_hits, 0)
}
