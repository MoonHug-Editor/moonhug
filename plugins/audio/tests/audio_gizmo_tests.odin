package audio_tests

// AudioSource handles (audio_editor.audio_source_handles) through the real
// hook: the min distance pushes the max out and lets it back, one undo step.

import "core:testing"
import "moonhug:engine"
import "moonhug:editor/handles"
import "moonhug:editor/undo"
import audio "moonhug:packages/audio"
import audio_editor "moonhug:packages/audio/editor"
import common "moonhug:tests/common"

@(private = "file")
_body :: proc(user: rawptr) {
	audio_editor.audio_source_handles(cast(^audio.AudioSource)user, handles.Gizmo_Context{state = {.Selected}, tool = .Translate})
}

@(test)
test_audio_distance_handles :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	s := new(undo.Undo_Stack)
	undo.init(s)
	undo.install(s)
	defer free(s)
	defer undo.destroy(s)

	tH := engine.transform_new("Source")
	_, raw := engine.transform_add_comp(tH, .AudioSource)
	a := cast(^audio.AudioSource)raw
	a.enabled = true
	a.min_distance = 1
	a.max_distance = 2
	v := common.handles_test_view()

	// The min distance's +X dot from 1 out to 3 pushes the max to 3.
	steps := s.top
	common.handles_drag(v, {1, 0, 0}, {3, 0, 0}, _body, a)
	testing.expectf(t, abs(a.min_distance - 3) < 1e-3 && abs(a.max_distance - 3) < 1e-3, "pushed: %v %v", a.min_distance, a.max_distance)
	testing.expect_value(t, s.top, steps + 1)
	undo.apply_undo(s)
	testing.expect(t, a.min_distance == 1 && a.max_distance == 2, "one step takes both back")
}
