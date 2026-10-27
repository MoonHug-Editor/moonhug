package editor_tests

// Window instances (editor/window): a window opens once plainly and once per
// asset, opening the same asset again returns its instance, an asset
// instance's tab names that asset's document, closing an instance frees its
// state through the window's closed proc, and saved keys reopen the
// instances whose window and asset still exist. Add Tab opens numbered
// instances, each under the lowest free number.

import "core:encoding/uuid"
import "core:fmt"
import "core:testing"
import "moonhug:editor/session"
import wnd "moonhug:editor/window"
import core "moonhug:libs/core"

@(private = "file") _ASSET_A :: "2b6f0d3e-91a4-4c27-8e5b-7d1c3a9f4e10"
@(private = "file") _ASSET_B :: "6e83a1c5-0f2d-4b98-a7c4-1d5e9b2f8a63"

@(private = "file")
_fixture: struct {
	registered: bool,
	closed:     int, // closed proc calls
}

@(private = "file")
_guid :: proc(s: string) -> core.Asset_GUID {
	g, _ := uuid.read(s)
	return core.Asset_GUID(g)
}

// A window with per-instance state, and a stand-in owner holding asset A's
// document. Registered once for the test process.
@(private = "file")
_fixture_register :: proc() {
	if _fixture.registered do return
	_fixture.registered = true
	wnd.register("instance_test", "Instance Test", "X", proc(w: ^wnd.Window) {}, 0, 0, closed = proc(w: ^wnd.Window) {
		_fixture.closed += 1
		free(w.data)
		w.data = nil
	})
	session.document_owner_add({
		name = "window_instance_test",
		list = proc(out: ^[dynamic]session.Document) {
			append(out, session.Document{guid = _guid(_ASSET_A), path = "assets/A.mat", can_discard = true})
		},
		save = proc(key: rawptr) -> bool {return true},
		discard = proc(key: rawptr) {},
	})
}

@(test)
test_window_instances_per_asset :: proc(t: ^testing.T) {
	_fixture_register()
	a, b := _guid(_ASSET_A), _guid(_ASSET_B)
	key_a := fmt.tprintf("instance_test/%s", _ASSET_A)
	key_b := fmt.tprintf("instance_test/%s", _ASSET_B)

	plain := wnd.open("instance_test")
	wa := wnd.open("instance_test", a)
	wb := wnd.open("instance_test", b)
	testing.expect(t, plain != nil && wa != nil && wb != nil, "every open returns its instance")
	if plain == nil || wa == nil || wb == nil do return
	testing.expect(t, wnd.open("instance_test", a) == wa, "opening the same asset again returns its instance")
	testing.expect_value(t, plain.key, "instance_test")
	testing.expect_value(t, wa.key, key_a)
	testing.expect(t, wa.asset == a && wb.asset == b, "each instance knows its asset")

	// The draw proc keeps its state in the instance.
	wa.data = new(int)
	wb.data = new(int)

	d, ok := session.view_document(key_a)
	testing.expect(t, ok && d.guid == a, "asset A's instance names A's document")
	_, none := session.view_document(key_b)
	testing.expect(t, !none, "asset B has no open document")

	keys := wnd.open_keys()
	testing.expect_value(t, len(keys), 3)

	before := _fixture.closed
	wnd.close(key_a)
	wnd.close(key_b)
	wnd.close("instance_test")
	wnd.draw_all() // removes closed instances, draws nothing
	testing.expect_value(t, _fixture.closed - before, 3)
	testing.expect(t, !wnd.is_open("instance_test"), "every instance is gone")
	_, still := session.view_document(key_a)
	testing.expect(t, !still, "a closed instance names no document")

	// A saved key reopens when its window exists. Asset A is not in the
	// asset database here, so its instance stays closed.
	wnd.open_saved({"instance_test", key_a, "no_such_window"})
	testing.expect(t, wnd.find("instance_test") != nil, "the plain instance reopens")
	testing.expect(t, wnd.find(key_a) == nil, "an instance whose asset is gone does not")
	wnd.close("instance_test")
	wnd.draw_all()
}

@(test)
test_window_numbered_instances :: proc(t: ^testing.T) {
	_fixture_register()
	plain := wnd.open("instance_test")
	two := wnd.open_another("instance_test")
	three := wnd.open_another("instance_test")
	testing.expect(t, plain != nil && two != nil && three != nil, "every open returns its instance")
	if plain == nil || two == nil || three == nil do return
	testing.expect_value(t, two.key, "instance_test/2")
	testing.expect_value(t, three.key, "instance_test/3")
	testing.expect(t, two.asset == {} && three.asset == {}, "a numbered instance has no asset")

	list := wnd.instances("instance_test")
	testing.expect(t, len(list) == 3 && list[0] == plain, "the plain instance comes first")

	// A closed number is the next one handed out. draw_all is not called
	// while instances are open: it would draw them.
	wnd.close("instance_test/2")
	again := wnd.open_another("instance_test")
	testing.expect(t, again != nil && again.key == "instance_test/2", "the lowest free number is reused")

	for w in wnd.instances("instance_test") do wnd.close(w.key)
	wnd.draw_all()
	testing.expect(t, !wnd.is_open("instance_test"), "every instance is gone")

	// A saved numbered key reopens.
	wnd.open_saved({"instance_test/4"})
	testing.expect(t, wnd.find("instance_test/4") != nil, "a numbered instance reopens")
	wnd.close("instance_test/4")
	wnd.draw_all()
}

// The copy opened or clicked in last is the one code outside a view acts
// on, and a window's plain state needs no closed proc: the copy frees it.
@(test)
test_window_last_and_state :: proc(t: ^testing.T) {
	if !wnd.is_registered("state_test") {
		wnd.register("state_test", "State Test", "X", proc(w: ^wnd.Window) {}, 0, 0)
	}
	Probe :: struct {
		count: int,
		label: string,
	}
	first := wnd.open("state_test")
	second := wnd.open_another("state_test")
	testing.expect(t, first != nil && second != nil, "both copies open")
	if first == nil || second == nil do return
	testing.expect(t, wnd.last("state_test") == second, "the copy opened last is the last one")
	testing.expect(t, wnd.open("state_test") == first && wnd.last("state_test") == first, "opening the plain copy again makes it the last one")

	st := wnd.state(first, Probe{count = 3, label = "a"})
	testing.expect(t, st.count == 3 && st.label == "a", "the state starts from its init value")
	st.count += 1
	testing.expect_value(t, wnd.state(first, Probe{}).count, 4)
	testing.expect(t, wnd.state(second, Probe{}) != st, "each copy has its own state")

	for w in wnd.instances("state_test") do wnd.close(w.key)
	wnd.draw_all() // frees both states, no closed proc needed
	testing.expect(t, wnd.last("state_test") == nil, "no copy is open")
}

// A hosted instance (a workspace frame's view) opens from its key, never
// draws as a window of its own, is left out of the saved layout (the
// workspace saves it), and gets its own window back on release.
@(test)
test_window_hosted_instances :: proc(t: ^testing.T) {
	_fixture_register()
	w := wnd.host_open("instance_test/7", "workspace")
	testing.expect(t, w != nil && w.host == "workspace", "the key opens a hosted instance")
	if w == nil do return
	testing.expect_value(t, len(wnd.hosted_by("workspace")), 1)
	for k in wnd.open_keys() do testing.expect(t, k != "instance_test/7", "a hosted instance is not in the saved layout")
	wnd.draw_all() // draws nothing: there is no imgui frame, so drawing would crash
	testing.expect(t, wnd.host_open("instance_test/7", "workspace") == w, "opening it again finds it")

	wnd.host_release(w)
	testing.expect(t, w.host == "" && len(wnd.hosted_by("workspace")) == 0, "released, it is a window of its own")
	wnd.close(w.key)
	wnd.draw_all()
}

// One host at a time: a second host's host_open gets nil while the first
// claims the instance each draw pass. A hosted instance no host claims in a
// pass gets its own window back at the end of draw_all, unless its host is
// open and did not draw (a hidden tab). No host here is a drawn window: a
// host that drew is marked as draw_content marks it.
@(test)
test_window_host_ownership :: proc(t: ^testing.T) {
	_fixture_register()
	a := wnd.host_open("instance_test/11", "host_a")
	testing.expect(t, a != nil && a.host == "host_a", "host A holds it")
	if a == nil do return
	testing.expect(t, wnd.host_open("instance_test/11", "host_b") == nil, "host B gets nil")
	testing.expect(t, wnd.host_held_elsewhere("instance_test/11", "host_b"), "B sees it held elsewhere")
	testing.expect(t, !wnd.host_held_elsewhere("instance_test/11", "host_a"), "A does not")
	wnd.draw_all() // A claimed it this pass: it stays hosted
	testing.expect_value(t, a.host, "host_a")
	testing.expect(t, wnd.host_open("instance_test/11", "host_b") == nil, "claimed last pass, B still gets nil")

	// A pass where A does not claim it, and A is no open window (it closed):
	// released, it is a window of its own, so any host may take it.
	wnd.draw_all()
	testing.expect_value(t, a.host, "")
	testing.expect(t, wnd.host_open("instance_test/11", "host_b") == a && a.host == "host_b", "B takes it")
	wnd.close(a.key)
	wnd.draw_all() // removes it: a window of its own would draw, and there is no imgui frame

	// A host that is an open instance (hosted itself, so nothing draws it
	// here) and did not draw keeps what it holds.
	h := wnd.host_open("instance_test/12", "outer")
	testing.expect(t, h != nil, "the host opens")
	if h == nil do return
	c := wnd.host_open("instance_test/13", h.key)
	testing.expect(t, c != nil, "the host holds a view")
	defer {
		wnd.close(h.key)
		if c != nil do wnd.close(c.key)
		wnd.draw_all()
	}
	if c == nil do return
	wnd.host_open(h.key, "outer")
	wnd.draw_all()
	wnd.host_open(h.key, "outer")
	wnd.draw_all()
	testing.expect_value(t, c.host, h.key) // its host did not draw: kept
	// The host draws and no longer claims it: released.
	wnd.host_open(h.key, "outer")
	h.ran = wnd._pass + 1
	wnd.draw_all()
	testing.expect_value(t, c.host, "")
}
