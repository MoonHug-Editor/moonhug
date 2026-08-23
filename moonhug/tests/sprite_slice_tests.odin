package tests

import "../engine"
import sprites "moonhug:packages/sprites"
import "core:testing"

// sprite_quad resolves slices from Texture2D.sprites: corners sized by the
// pixel rect and pivot, uvs normalized from the rect (top-left origin).
@(test)
test_sprite_quad_slice_and_whole_texture :: proc(t: ^testing.T) {
	rects := [2]engine.Sprite_Rect{
		{id = 11, name = "a", rect = {0, 0, 100, 100}, pivot = {0.5, 0.5}},
		{id = 22, name = "b", rect = {100, 0, 100, 50}, pivot = {0, 0}},
	}
	tex := engine.Texture2D{
		width           = 200,
		height          = 100,
		pixels_per_unit = 100,
		sprites         = rects[:],
	}
	tw := engine.Transform_World{
		rotation = engine.QUAT_IDENTITY,
		scale    = {1, 1, 1},
	}

	// local_id 0: the whole texture, 2 x 1 world units centered on the
	// transform, full-quad uvs — the pre-slicing behavior.
	sr: sprites.SpriteRenderer
	c, uvs, ok := sprites.sprite_quad(&sr, tw, &tex)
	testing.expect(t, ok)
	testing.expect_value(t, c[0], [3]f32{-1, -0.5, 0})
	testing.expect_value(t, c[2], [3]f32{1, 0.5, 0})
	testing.expect_value(t, uvs, engine.QUAD_UVS_FULL)

	// Slice b: 1 x 0.5 units, bottom-left pivot puts the transform at bl.
	sr.sprite.local_id = 22
	c, uvs, ok = sprites.sprite_quad(&sr, tw, &tex)
	testing.expect(t, ok)
	testing.expect_value(t, c[0], [3]f32{0, 0, 0})
	testing.expect_value(t, c[2], [3]f32{1, 0.5, 0})
	// Pixel rect {100, 0, 100, 50} of 200x100: u 0.5..1, v 0..0.5.
	testing.expect_value(t, uvs[0], [2]f32{0.5, 0.5})
	testing.expect_value(t, uvs[2], [2]f32{1, 0})

	// An id no slice carries renders nothing.
	sr.sprite.local_id = 99
	_, _, ok = sprites.sprite_quad(&sr, tw, &tex)
	testing.expect(t, !ok)
}
