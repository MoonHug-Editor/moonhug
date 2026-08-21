package tests

// The inspector funnel's mechanics, headless: chain composition, order
// bands, the asset wildcard merge, and the four wrapper capabilities
// (prepend/append/wrap/replace). Wrappers here log instead of drawing, and
// the component base is reached through a registered custom drawer, so
// no imgui context is needed.

import "core:strings"
import "core:testing"
import inspector "../editor/inspector"

_Funnel_Probe :: struct {
	x: f32,
}

// The log the fake wrappers write into. Package-global — wrapper procs
// cannot capture locals.
@(private = "file")
_funnel_log: [dynamic]string

@(private = "file")
_log_joined :: proc() -> string {
	return strings.join(_funnel_log[:], " ", context.temp_allocator)
}

@(private = "file")
_outer :: proc(ctx: ^inspector.Component_Ctx) {
	append(&_funnel_log, "outer>")
	inspector.draw(ctx)
	append(&_funnel_log, "<outer")
}

@(private = "file")
_inner :: proc(ctx: ^inspector.Component_Ctx) {
	append(&_funnel_log, "inner>")
	inspector.draw(ctx)
	append(&_funnel_log, "<inner")
}

@(private = "file")
_replace :: proc(ctx: ^inspector.Component_Ctx) {
	append(&_funnel_log, "replaced")
	// never calls inspector.draw — the rest of the chain and the default drawing are skipped
}

@(test)
test_funnel_component_chain_order_and_base :: proc(t: ^testing.T) {
	if inspector.mapPropertyDrawer == nil {
		inspector.mapPropertyDrawer = make(inspector.MapPropertyDrawer)
	}
	inspector.mapPropertyDrawer[typeid_of(_Funnel_Probe)] =
		proc(ptr: rawptr, tid: typeid, label: cstring) { append(&_funnel_log, "base") }
	defer delete_key(&inspector.mapPropertyDrawer, typeid_of(_Funnel_Probe))
	defer {
		delete(_funnel_log)
		_funnel_log = {}
	}

	// Registered inner-first, but the WRAP band pulls _outer outside.
	inspector.add_component_wrapper(typeid_of(_Funnel_Probe), _inner)
	inspector.add_component_wrapper(typeid_of(_Funnel_Probe), _outer, order = inspector.ORDER_OUTER)

	chain, has := inspector._component_chain(typeid_of(_Funnel_Probe))
	testing.expect(t, has && len(chain) == 2)

	probe := _Funnel_Probe{}
	clear(&_funnel_log)
	ctx := inspector.Component_Ctx{ptr = &probe, tid = typeid_of(_Funnel_Probe), _chain = chain}
	inspector._funnel_draw(&ctx)
	testing.expect_value(t, _log_joined(), "outer> inner> base <inner <outer")

	// Replace: a wrapper that skips inspector.draw(ctx) cuts off everything inside it.
	inspector.add_component_wrapper(typeid_of(_Funnel_Probe), _replace, order = inspector.ORDER_INNER)
	chain2, _ := inspector._component_chain(typeid_of(_Funnel_Probe))
	clear(&_funnel_log)
	ctx2 := inspector.Component_Ctx{ptr = &probe, tid = typeid_of(_Funnel_Probe), _chain = chain2}
	inspector._funnel_draw(&ctx2)
	testing.expect_value(t, _log_joined(), "outer> inner> replaced <inner <outer")
}

@(private = "file")
_asset_specific :: proc(ctx: ^inspector.Asset_Ctx) {
	append(&_funnel_log, "specific")
}

@(private = "file")
_asset_wildcard :: proc(ctx: ^inspector.Asset_Ctx) {
	append(&_funnel_log, "wildcard>")
	inspector.draw(ctx)
	append(&_funnel_log, "<wildcard")
}

@(test)
test_funnel_asset_wildcard_merge :: proc(t: ^testing.T) {
	// The wildcard ("") wraps every asset — the WRAP band puts it outside
	// the importer-specific wrapper regardless of registration order.
	inspector.add_asset_wrapper("funnel_test_importer", _asset_specific)
	inspector.add_asset_wrapper("", _asset_wildcard, order = inspector.ORDER_OUTER)
	defer {
		delete(_funnel_log)
		_funnel_log = {}
	}

	chain, has := inspector._asset_chain("funnel_test_importer")
	testing.expect(t, has && len(chain) == 2, "importer + wildcard merge into one chain")

	clear(&_funnel_log)
	ctx := inspector.Asset_Ctx{path = "probe.test", _chain = chain}
	inspector._funnel_draw(&ctx)
	// _asset_specific never calls inspector.draw, so the default drawing (imgui) is not hit.
	testing.expect_value(t, _log_joined(), "wildcard> specific <wildcard")

	// An importer with no wrappers of its own still gets the wildcard.
	solo, solo_has := inspector._asset_chain("some_other_importer")
	testing.expect(t, solo_has && len(solo) == 1, "wildcard alone still wraps")

	// No wrappers anywhere relevant: no chain, the host draws the default.
	inspector._asset_wrappers = {}
	none, none_has := inspector._asset_chain("funnel_test_importer")
	testing.expect(t, !none_has && none == nil, "empty registry means no chain")
}
