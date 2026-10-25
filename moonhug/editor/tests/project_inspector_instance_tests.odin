package editor_tests

// Project Inspector instances (inspector/project_inspector_window.odin): each
// instance has its own state and lock, the project selection retargets every
// unlocked instance, and a closed instance's state goes with it.

import "core:testing"
import "moonhug:editor/inspector"
import wnd "moonhug:editor/window"

@(test)
test_project_inspector_instances_route_unlocked :: proc(t: ^testing.T) {
	PI :: inspector.PROJECT_INSPECTOR
	if !wnd.is_registered(PI) {
		wnd.register(PI, PI, "X", inspector.project_inspector_window_draw, 0, 0, closed = inspector.project_inspector_window_closed)
	}
	wnd.open(PI)
	second := wnd.open_another(PI)
	testing.expect(t, second != nil, "another instance opens")
	if second == nil do return
	defer {
		inspector.project_inspector_lock(PI)^ = false
		wnd.close(second.key)
		wnd.close(PI)
		wnd.draw_all()
	}

	first_data := inspector.project_inspector_data(PI)
	second_data := inspector.project_inspector_data(second.key)
	testing.expect(t, first_data != nil && second_data != nil && first_data != second_data, "each instance has its own state")

	targets := inspector.route_targets()
	testing.expect(t, len(targets) == 2 && targets[0] == first_data && targets[1] == second_data, "the selection reaches both")

	inspector.project_inspector_lock(second.key)^ = true
	targets = inspector.route_targets()
	testing.expect(t, len(targets) == 1 && targets[0] == first_data, "a locked instance keeps what it shows")

	inspector.project_inspector_lock(PI)^ = true
	testing.expect_value(t, len(inspector.route_targets()), 0)

	key := second.key
	wnd.close(key)
	inspector.project_inspector_lock(PI)^ = false
	testing.expect(t, inspector.project_inspector_data(key) == nil, "a closed instance has no state")
	targets = inspector.route_targets()
	testing.expect(t, len(targets) == 1 && targets[0] == first_data, "the first instance stays routed")
}
