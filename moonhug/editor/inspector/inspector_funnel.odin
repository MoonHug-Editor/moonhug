package inspector

// Inspector funnel: registered wrappers stack around the default drawing of
// a value. The chain runs outermost to innermost and ends at the default
// drawing:
//
//   inspector ──▶ wrapper A ──▶ wrapper B ──▶ default drawing
//                 draw(ctx)     draw(ctx)
//
// draw(ctx) draws everything BENEATH the calling wrapper — the rest of the
// chain, ending at the default drawing. One rule: rows drawn before the
// call appear above the default drawing, rows drawn after appear below it,
// and skipping the call replaces it entirely (the wrapper then owns
// undo/multiedit itself). Call it at most once.
//
// Odin has no closures, so the ctx carries the chain and a cursor instead
// of a captured continuation.
//
// Wrappers sort by (order, registration sequence), lower = outer. The bands
// keep independent packages composing without coordinating numbers.
//
// Two funnels share the mechanics:
// - Component/value funnel: keyed by typeid, wraps every struct the
//   inspector draws (components, nested structs, asset docs). The default
//   drawing is the type's custom drawer (mapPropertyDrawer) or the
//   reflected field loop.
// - Asset funnel: keyed by IMPORTER NAME ("" wraps every asset), wraps the
//   import-settings body. The default drawing is the Apply button +
//   reflected settings.

import "base:runtime"
import "core:slice"
import engine "../../engine"

ORDER_OUTER :: -1000 // outermost frames (headers, foldouts, banners)
ORDER_MIDDLE :: 0 // ordinary prepend/append rows
ORDER_INNER :: 1000 // closest to the default drawing

// --- Component/value funnel --------------------------------------------------

Component_Ctx :: struct {
	ptr:         rawptr,
	tid:         typeid,
	label:       cstring,
	path_prefix: string,
	_chain:      []Component_Wrapper,
	_index:      int,
}

Component_Wrapper :: proc(ctx: ^Component_Ctx)

// --- Asset funnel --------------------------------------------------------------

Asset_Ctx :: struct {
	path:     string,
	guid:     engine.Asset_GUID,
	settings: any, // the typed settings instance being edited
	_chain:   []Asset_Wrapper,
	_index:   int,
}

Asset_Wrapper :: proc(ctx: ^Asset_Ctx)

// Wrapper-facing: draw the inspected value as everything beneath the
// calling wrapper defines it — the rest of the chain, ending at the
// default drawing.
draw :: proc {
	draw_component,
	draw_asset,
}

draw_component :: proc(ctx: ^Component_Ctx) {
	ctx._index += 1
	if ctx._index < len(ctx._chain) {
		ctx._chain[ctx._index](ctx)
	} else {
		draw_inspector_default(ctx.ptr, ctx.tid, ctx.label, ctx.path_prefix)
	}
}

draw_asset :: proc(ctx: ^Asset_Ctx) {
	ctx._index += 1
	if ctx._index < len(ctx._chain) {
		ctx._chain[ctx._index](ctx)
	} else {
		draw_default_import_settings()
	}
}

// Host-facing: run the value through the funnel from the top (the whole
// chain, then the default drawing).
_funnel_draw :: proc {
	_funnel_draw_component,
	_funnel_draw_asset,
}

_funnel_draw_component :: proc(ctx: ^Component_Ctx) {
	ctx._index = -1
	draw_component(ctx)
}

_funnel_draw_asset :: proc(ctx: ^Asset_Ctx) {
	ctx._index = -1
	draw_asset(ctx)
}

// --- Registration --------------------------------------------------------------

_Component_Entry :: struct {
	fn:    Component_Wrapper,
	order: int,
	seq:   int,
}

_Asset_Entry :: struct {
	fn:    Asset_Wrapper,
	order: int,
	seq:   int,
}

_component_wrappers: map[typeid][dynamic]_Component_Entry
_asset_wrappers: map[string][dynamic]_Asset_Entry
_wrapper_seq: int

add_component_wrapper :: proc(tid: typeid, fn: Component_Wrapper, order := ORDER_MIDDLE) {
	// Registry state never borrows the caller's allocator.
	context.allocator = runtime.default_allocator()
	if _component_wrappers == nil do _component_wrappers = make(map[typeid][dynamic]_Component_Entry)
	if tid not_in _component_wrappers do _component_wrappers[tid] = make([dynamic]_Component_Entry)
	entries := &_component_wrappers[tid]
	_wrapper_seq += 1
	append(entries, _Component_Entry{fn, order, _wrapper_seq})
	slice.sort_by(entries[:], proc(a, b: _Component_Entry) -> bool {
		return a.order < b.order || (a.order == b.order && a.seq < b.seq)
	})
}

// importer: the Importer_Desc name owning the asset's extension. "" wraps
// EVERY asset's inspector.
add_asset_wrapper :: proc(importer: string, fn: Asset_Wrapper, order := ORDER_MIDDLE) {
	context.allocator = runtime.default_allocator()
	if _asset_wrappers == nil do _asset_wrappers = make(map[string][dynamic]_Asset_Entry)
	if importer not_in _asset_wrappers do _asset_wrappers[importer] = make([dynamic]_Asset_Entry)
	entries := &_asset_wrappers[importer]
	_wrapper_seq += 1
	append(entries, _Asset_Entry{fn, order, _wrapper_seq})
	slice.sort_by(entries[:], proc(a, b: _Asset_Entry) -> bool {
		return a.order < b.order || (a.order == b.order && a.seq < b.seq)
	})
}

// --- Chain build ---------------------------------------------------------------
// Built per draw into the temp allocator — registration order stays
// irrelevant to composition.

_component_chain :: proc(tid: typeid) -> (chain: []Component_Wrapper, has: bool) {
	entries, ok := _component_wrappers[tid]
	if !ok || len(entries) == 0 do return nil, false
	out := make([]Component_Wrapper, len(entries), context.temp_allocator)
	for e, i in entries do out[i] = e.fn
	return out, true
}

// The importer's wrappers merged with the "" wildcard's, one sorted chain.
_asset_chain :: proc(importer: string) -> (chain: []Asset_Wrapper, has: bool) {
	merged := make([dynamic]_Asset_Entry, context.temp_allocator)
	if entries, ok := _asset_wrappers[importer]; ok do append(&merged, ..entries[:])
	if importer != "" {
		if entries, ok := _asset_wrappers[""]; ok do append(&merged, ..entries[:])
	}
	if len(merged) == 0 do return nil, false
	slice.sort_by(merged[:], proc(a, b: _Asset_Entry) -> bool {
		return a.order < b.order || (a.order == b.order && a.seq < b.seq)
	})
	out := make([]Asset_Wrapper, len(merged), context.temp_allocator)
	for e, i in merged do out[i] = e.fn
	return out, true
}
