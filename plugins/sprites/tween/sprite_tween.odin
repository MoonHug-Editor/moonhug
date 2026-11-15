package sprites_tween

// One-line tweens for the sprites plugin's component, owned here because the
// thing they animate is its SpriteRenderer. The folder compiles only with the
// tween plugin installed (docs/core/Plugins.md).
//
//   import sprites_tween "moonhug:packages/sprites/tween"
//
//   sprites_tween.alpha(ghost, 0, 0.5)
//   sprites_tween.color(enemy, {1, 0, 0, 1}, 0.1, opt = {cycles = 2, cycle_mode = .Yoyo})

import "moonhug:packages/engine"
import sprites "moonhug:packages/sprites"
import tween "moonhug:packages/tween"

// A sprite's color from what it is to `to`.
color :: proc(target: engine.Transform_Handle, to: [4]f32, timing: tween.Timing, ease := tween.Ease.Linear, opt := tween.Options{}) -> tween.Handle {
	return tween.field(target, _color_of, to, timing, ease, opt)
}

// A sprite's alpha, its color staying what it is.
alpha :: proc(target: engine.Transform_Handle, to: f32, timing: tween.Timing, ease := tween.Ease.Linear, opt := tween.Options{}) -> tween.Handle {
	return tween.field_masked(target, _color_of, {0, 0, 0, to}, 4, {3}, timing, ease, opt)
}

@(private = "file")
_color_of :: proc(target: engine.Transform_Handle) -> rawptr {
	_, sr := sprites.get_comp(target, sprites.SpriteRenderer)
	return &sr.color if sr != nil else nil
}
