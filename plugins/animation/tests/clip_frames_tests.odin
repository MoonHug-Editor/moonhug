package animation_tests

// Frame grid and key ordering: the pure rules the animation window's snapping
// and multi-key drag are built on.

import "core:testing"
import "moonhug:engine"
import anim "moonhug:packages/animation"
import common "moonhug:tests/common"

@(test)
test_frame_rate_defaults_for_a_clip_without_one :: proc(t: ^testing.T) {
	// A clip saved before the field existed reads 0, which would make every
	// frame conversion divide by zero.
	c := anim.AnimationClip{}
	testing.expect_value(t, anim.animation_clip_frame_rate(&c), anim.ANIMATION_FRAME_RATE_DEFAULT)
	c.frame_rate = -5
	testing.expect_value(t, anim.animation_clip_frame_rate(&c), anim.ANIMATION_FRAME_RATE_DEFAULT)
	c.frame_rate = 30
	testing.expect_value(t, anim.animation_clip_frame_rate(&c), f32(30))
}

@(test)
test_snap_to_frame_rounds_to_the_grid :: proc(t: ^testing.T) {
	c := anim.AnimationClip{frame_rate = 10} // 0.1s per frame
	testing.expect_value(t, anim.animation_snap_to_frame(&c, 0.04), f32(0))
	testing.expect_value(t, anim.animation_snap_to_frame(&c, 0.06), f32(0.1))
	testing.expect_value(t, anim.animation_snap_to_frame(&c, 0.5), f32(0.5))
	// Already on the grid: unchanged.
	testing.expect_value(t, anim.animation_snap_to_frame(&c, 1.2), f32(1.2))
}

@(test)
test_key_bounds_are_the_neighbouring_keys :: proc(t: ^testing.T) {
	times := []f32{0, 1, 2, 3}
	sel := []bool{false, true, false, false}
	lo, hi := anim.animation_key_bounds(times, sel, 1, 4)
	testing.expect_value(t, lo, f32(0))
	testing.expect_value(t, hi, f32(2))
}

@(test)
test_key_bounds_at_the_ends_use_zero_and_length :: proc(t: ^testing.T) {
	times := []f32{0.5, 1, 2}
	sel := []bool{true, false, false}
	lo, hi := anim.animation_key_bounds(times, sel, 0, 9)
	testing.expect_value(t, lo, f32(0))
	testing.expect_value(t, hi, f32(1))

	sel2 := []bool{false, false, true}
	lo2, hi2 := anim.animation_key_bounds(times, sel2, 2, 9)
	testing.expect_value(t, lo2, f32(1))
	testing.expect_value(t, hi2, f32(9)) // the clip's length
}

@(test)
test_key_bounds_skip_selected_neighbours :: proc(t: ^testing.T) {
	// Keys 1 and 2 move together, so they do not bound each other: the block
	// may slide from key 0 up to key 3. Without this a run of adjacent
	// selected keys could not move at all.
	times := []f32{0, 1, 2, 3}
	sel := []bool{false, true, true, false}
	lo, hi := anim.animation_key_bounds(times, sel, 1, 4)
	testing.expect_value(t, lo, f32(0))
	testing.expect_value(t, hi, f32(3))

	lo2, hi2 := anim.animation_key_bounds(times, sel, 2, 4)
	testing.expect_value(t, lo2, f32(0))
	testing.expect_value(t, hi2, f32(3))
}

@(test)
test_key_bounds_whole_channel_selected :: proc(t: ^testing.T) {
	// Everything selected: the block is free within the clip.
	times := []f32{0, 1, 2}
	sel := []bool{true, true, true}
	lo, hi := anim.animation_key_bounds(times, sel, 1, 5)
	testing.expect_value(t, lo, f32(0))
	testing.expect_value(t, hi, f32(5))
}

@(test)
test_key_bounds_out_of_range_index_is_inert :: proc(t: ^testing.T) {
	times := []f32{0, 1}
	sel := []bool{false, false}
	lo, hi := anim.animation_key_bounds(times, sel, 7, 3)
	testing.expect_value(t, lo, f32(0))
	testing.expect_value(t, hi, f32(3))
}

// A channel with no keys contributes nothing. Sampling one yields zeros, and
// applying those would collapse a scale or snap a position to the origin, so
// both apply paths skip it.
@(test)
test_empty_channel_does_not_apply :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	tH := engine.transform_new("A")
	tr := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH))
	tr.scale = {2, 3, 4}
	tr.position = {5, 6, 7}

	clip := anim.AnimationClip{length = 1}
	defer delete(clip.channels)
	// Two keyless channels that would otherwise write zeros.
	append(&clip.channels, anim.Animation_Channel{path = .Scale})
	append(&clip.channels, anim.Animation_Channel{path = .Position})
	defer for &ch in clip.channels {
		delete(ch.times)
		delete(ch.values)
	}

	anim.animation_clip_apply(&clip, tH, 0.5)

	testing.expect_value(t, tr.scale, [3]f32{2, 3, 4})
	testing.expect_value(t, tr.position, [3]f32{5, 6, 7})
}
