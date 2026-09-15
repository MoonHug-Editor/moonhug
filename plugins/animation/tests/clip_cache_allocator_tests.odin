package animation_tests

// The clip cache owns its memory.
//
// A cache entry outlives the call that created it, so it must not be allocated
// from whatever allocator the caller happened to be running under. The Playable
// Graph window builds the authored shape into TEMP memory
// (editor/view_playable_graph.odin), and that build asks every entry's clip for
// its length and wrap — so a clip first loaded through that window landed its
// channels in the frame's temp arena. free_all reclaimed them at the end of the
// frame, the cache kept the entry, and every later load handed out the dangling
// one. The scrub preview then posed from freed memory and froze on a stale
// frame, but only when the graph window happened to be open as the scrub began.
//
// The test drives the cache under a substitute allocator and asserts it took
// nothing from it. That is the invariant, and it holds however the freed memory
// is later reused — inspecting the freed bytes instead would pass or fail on
// luck. `animation_clip_load` carries the same pin for the same reason: its
// path needs a built artifact, which a headless suite has no guarantee of, so
// this covers the invariant through the one entry point that is reachable here.

import "core:mem"
import "core:testing"
import anim "moonhug:packages/animation"
import common "moonhug:tests/common"

@(test)
test_clip_cache_does_not_borrow_caller_allocator :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// Ordered so the cache is emptied BEFORE the tracking allocator goes away:
	// if the entry did borrow it, the shutdown has to be able to give it back.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()

	doc := _const_clip(.Position, {7, 0, 0, 0}, length = 2)
	defer anim._animation_clip_destroy(&doc)

	guid := _clip_guid(77)
	{
		// The caller's allocator, standing in for the temp arena the editor's
		// draw paths are running under when they reach the cache.
		context.allocator = mem.tracking_allocator(&track)
		anim.animation_clip_preview(guid, doc)
	}

	testing.expect_value(t, len(track.allocation_map), 0)

	// And the entry is intact and independent of the source.
	cached, ok := anim.animation_clip_load(guid)
	testing.expect(t, ok, "the preview entry is cached")
	if !ok do return
	testing.expect(t, abs(cached.length - 2) < 0.001, "cached length survives")
	testing.expect(t, abs(cached.channels[0].values[0].x - 7) < 0.001, "cached values survive")
}
