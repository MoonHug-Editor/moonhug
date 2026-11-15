package sprites_tween_tests

// The sprites plugin's one-line tweens (sprites/tween).

import "core:testing"
import "moonhug:packages/engine"
import sprites "moonhug:packages/sprites"
import sprites_tween "moonhug:packages/sprites/tween"
import tween "moonhug:packages/tween"
import common "moonhug:tests/common"

@(test)
test_sprite_color_and_alpha :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()
	defer tween.stop_all()

	owner := engine.transform_new("Sprite")
	_, raw := engine.transform_add_comp(owner, .SpriteRenderer)
	sr := cast(^sprites.SpriteRenderer)raw
	sr.color = {1, 0.5, 0, 1}

	// Alpha alone: the color stays.
	sprites_tween.alpha(owner, 0, 0.5)
	for _ in 0 ..< 16 do tween.tick_all(1.0 / 64.0)
	testing.expect(t, abs(sr.color.a - 0.5) < 1e-4)
	testing.expect_value(t, sr.color.rgb, [3]f32{1, 0.5, 0})
	for _ in 0 ..< 17 do tween.tick_all(1.0 / 64.0)
	testing.expect_value(t, sr.color, [4]f32{1, 0.5, 0, 0})

	h := sprites_tween.color(owner, {0, 0, 1, 1}, 0.25)
	tween.complete(h)
	testing.expect_value(t, sr.color, [4]f32{0, 0, 1, 1})

	// No SpriteRenderer: the tween ends, nothing is written.
	bare := engine.transform_new("Bare")
	h = sprites_tween.alpha(bare, 0, 0.5)
	tween.tick_all(1.0 / 64.0)
	testing.expect(t, !tween.is_alive(h))
}
