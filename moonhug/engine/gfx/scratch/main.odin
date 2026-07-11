// Throwaway validation window for the gfx package (docs/SDL3Renderer.md
// phase 2 checkpoint): exercises swapchain + offscreen passes, the batch
// (quads/lines/overlay), mid-pass view_proj switches, and debug text.
// Run: odin run moonhug/engine/gfx/scratch -- [seconds]
// Deleted once the phase-3 cutover lands.
package gfx_scratch

import "core:os"
import "core:strconv"
import gfx "../"

main :: proc() {
	if !gfx.init("gfx scratch", 800, 600) {
		os.exit(1)
	}
	defer gfx.shutdown()

	auto_quit := f32(0)
	if len(os.args) > 1 {
		if secs, ok := strconv.parse_f32(os.args[1]); ok do auto_quit = secs
	}

	offscreen := gfx.rt_create(256, 256)
	defer gfx.rt_destroy(offscreen)

	elapsed := f32(0)
	frames := 0
	for !gfx.quit_requested() {
		gfx.poll_events()
		if !gfx.frame_begin() do continue
		elapsed += gfx.delta_time()
		frames += 1

		// Offscreen pass: validates target passes + a second copy/render
		// encoding in the same command buffer.
		gfx.pass_begin_target(offscreen, [4]f32{1, 0, 1, 1})
		gfx.draw_line({-1, -1, 0}, {1, 1, 0}, {1, 1, 1, 1})
		gfx.pass_end()

		if gfx.pass_begin_swapchain([4]f32{0.1, 0.12, 0.16, 1}) {
			// Identity view_proj = clip-space coords. A "triangle" via quad
			// with two coincident corners, plus a real quad.
			gfx.draw_quad(
				{{-0.8, -0.5, 0}, {-0.2, -0.5, 0}, {-0.5, 0.5, 0}, {-0.5, 0.5, 0}},
				{{0, 1}, {1, 1}, {0.5, 0}, {0.5, 0}},
				{1, 0.4, 0.1, 1}, nil,
			)
			gfx.draw_quad(
				{{0.2, -0.5, 0}, {0.8, -0.5, 0}, {0.8, 0.1, 0}, {0.2, 0.1, 0}},
				{{0, 1}, {1, 1}, {1, 0}, {0, 0}},
				{0.2, 0.8, 0.3, 0.8}, nil,
			)
			gfx.draw_line({-1, 0.8, 0}, {1, 0.8, 0}, {1, 1, 0, 1})
			gfx.draw_line({-1, 0.9, 0}, {1, 0.9, 0}, {0, 1, 1, 1}, depth_test = false)

			// Mid-pass view_proj switch to pixel space for text.
			ws := gfx.window_size()
			gfx.set_view_proj(gfx.matrix4_ortho_pixels(f32(ws.x), f32(ws.y)))
			gfx.debug_text({20, 20}, 16, {1, 1, 1, 1}, "gfx scratch: quads+lines+overlay+text OK")
			gfx.debug_text({20, 44}, 12, {0.7, 0.7, 0.7, 1}, "second line 0123456789 !?")
			gfx.pass_end()
		}
		gfx.frame_end()

		if auto_quit > 0 && elapsed > auto_quit {
			gfx.request_quit()
		}
	}
}
