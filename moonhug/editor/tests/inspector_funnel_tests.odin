package editor_tests

// The inspector funnel's mechanics, headless: chain composition, order
// bands, the four things a step can do (prepend, append, surround, replace),
// and the asset info an import settings step reads. Steps here log instead
// of drawing, and the chain's end is reached through an inner step that
// stands in for the default drawing, so no imgui context is needed.
//
// Each test drops every registration when it ends and registers the
// generated set again, so the tests after it see the editor's drawers.

import "core:strings"
import "core:testing"
import inspector "moonhug:editor/inspector"
import core "moonhug:libs/core"
import "moonhug:registration"

_Funnel_Probe :: struct {
	x: f32,
}

_Funnel_Settings_Probe :: struct {
	y: f32,
}

// The log the fake steps write into. Package-global: step procs cannot
// capture locals.
@(private = "file")
_funnel_log: [dynamic]string

@(private = "file")
_funnel_seen: inspector.Asset_Info

@(private = "file")
_log_joined :: proc() -> string {
	return strings.join(_funnel_log[:], " ", context.temp_allocator)
}

// Drops the test's registrations and restores the generated ones.
@(private = "file")
_funnel_restore :: proc() {
	inspector.drawers_reset()
	registration.register_property_drawers()
	delete(_funnel_log)
	_funnel_log = {}
}

@(private = "file")
_outer :: proc(ctx: ^inspector.Ctx) {
	append(&_funnel_log, "outer>")
	inspector.draw(ctx)
	append(&_funnel_log, "<outer")
}

@(private = "file")
_middle :: proc(ctx: ^inspector.Ctx) {
	append(&_funnel_log, "middle>")
	inspector.draw(ctx)
	append(&_funnel_log, "<middle")
}

@(private = "file")
_base :: proc(ctx: ^inspector.Ctx) {
	append(&_funnel_log, "base")
}

@(private = "file")
_replace :: proc(ctx: ^inspector.Ctx) {
	append(&_funnel_log, "replaced")
	// never calls inspector.draw: the rest of the chain and the default drawing are skipped
}

@(test)
test_funnel_chain_order_and_base :: proc(t: ^testing.T) {
	defer _funnel_restore()
	tid := typeid_of(_Funnel_Probe)

	// Registered inner-first, but the bands put _outer outside _middle and
	// _base innermost.
	inspector.add_drawer(tid, _base)
	inspector.add_drawer(tid, _middle, order = inspector.ORDER_MIDDLE)
	inspector.add_drawer(tid, _outer, order = inspector.ORDER_OUTER)
	testing.expect(t, inspector.has_drawer(tid))

	probe := _Funnel_Probe{}
	ctx := inspector.Ctx{ptr = &probe, tid = tid, _chain = inspector._chain_of(tid)}
	testing.expect_value(t, len(ctx._chain), 3)
	inspector._funnel_draw(&ctx)
	testing.expect_value(t, _log_joined(), "outer> middle> base <middle <outer")

	// Replace: a step that skips inspector.draw(ctx) cuts off everything inside it.
	inspector.add_drawer(tid, _replace, order = inspector.ORDER_MIDDLE + 1)
	clear(&_funnel_log)
	ctx2 := inspector.Ctx{ptr = &probe, tid = tid, _chain = inspector._chain_of(tid)}
	inspector._funnel_draw(&ctx2)
	testing.expect_value(t, _log_joined(), "outer> middle> replaced <middle <outer")
}

@(private = "file")
_settings_step :: proc(ctx: ^inspector.Ctx) {
	_funnel_seen = ctx.asset
	append(&_funnel_log, "settings")
}

@(test)
test_funnel_settings_step_reads_asset :: proc(t: ^testing.T) {
	defer _funnel_restore()
	tid := typeid_of(_Funnel_Settings_Probe)
	inspector.add_drawer(tid, _settings_step, order = inspector.ORDER_MIDDLE)
	_funnel_seen = {}

	guid := core.Asset_GUID{0 = 1, 1 = 2, 15 = 3}
	probe := _Funnel_Settings_Probe{}
	ctx := inspector.Ctx{
		ptr    = &probe,
		tid    = tid,
		label  = "Import Settings",
		asset  = {settings = true, path = "probe.test", guid = guid, sub = 7},
		_chain = inspector._chain_of(tid),
	}
	inspector._funnel_draw(&ctx)
	// _settings_step never calls inspector.draw, so the default drawing (imgui) is not hit.
	testing.expect_value(t, _log_joined(), "settings")
	testing.expect(t, _funnel_seen.settings)
	testing.expect_value(t, _funnel_seen.path, "probe.test")
	testing.expect_value(t, _funnel_seen.guid, guid)
	testing.expect_value(t, _funnel_seen.sub, core.Local_ID(7))
}

@(test)
test_funnel_reset_restores_generated :: proc(t: ^testing.T) {
	defer _funnel_restore()
	inspector.drawers_reset()
	testing.expect(t, !inspector.has_drawer(typeid_of(f32)))
	registration.register_property_drawers()
	testing.expect(t, inspector.has_drawer(typeid_of(f32)), "the generated set covers the built-in kinds")
	testing.expect(t, !inspector.has_drawer(typeid_of(_Funnel_Probe)), "a reset drops a test's steps")
}
