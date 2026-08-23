package tests

import "../engine"
import "core:math/linalg"
import "core:testing"

// The collector registry is the seam that lets renderer components live in
// packages: render_collect_commands runs every registered collector after
// the engine's built-in ones and render_execute sorts the combined list.
@(test)
test_registered_collector_feeds_command_list :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	engine.render_register_collector(proc(view: engine.Render_View, out: ^[dynamic]engine.Render_Command) {
		append(out, engine.Render_Command{
			variant = engine.Draw_Sprite{color = {1, 0, 0, 1}},
		})
	})
	defer clear(&engine._render_collectors)

	ident := linalg.MATRIX4F32_IDENTITY
	view := engine.render_view_make(ident, ident, 100, 100, max(u32))
	commands := make([dynamic]engine.Render_Command, 0, 4, context.temp_allocator)
	engine.render_collect_commands(view, &commands)

	testing.expect_value(t, len(commands), 1)
	_, is_sprite := commands[0].variant.(engine.Draw_Sprite)
	testing.expect(t, is_sprite, "the registered collector's command must come through")
}
