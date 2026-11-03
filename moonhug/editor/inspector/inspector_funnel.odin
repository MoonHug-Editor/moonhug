package inspector

// Inspector funnel: the chain of drawers that draws a value. Every value the
// inspector shows, a component, a nested struct, a field, an array element,
// an asset document, an asset's import settings, goes through the steps
// registered for its type, outermost first, and ends at the default drawing:
//
//   inspector ──▶ step A ──▶ step B ──▶ default drawing
//                 draw(ctx)  draw(ctx)
//
// A step is a proc declared with @(property_drawer={type=T, order=...}). It
// draws what it wants and calls draw(ctx) for everything beneath it: the rest
// of the chain, then the default drawing. Rows drawn before the call appear
// above, rows drawn after appear below, and skipping the call replaces the
// drawing. One rule, and one call at most.
//
// Steps sort by order, lower outside: ORDER_OUTER for frames and banners,
// ORDER_MIDDLE for ordinary rows around, ORDER_INNER for the type's own
// drawing, which is the default when the attribute gives no order. The bands
// let independent packages compose without coordinating numbers.
//
// The default drawing depends on the value:
// - a struct: the reflected field loop, each field a row of its own;
// - an asset's import settings: Apply and Revert, the file row, the fields;
// - anything else: the kind's built-in row, or its text.
//
// A value that can only be one row, every non-struct type, gets its edit
// (field_edit.odin) opened by the inspector around its chain: one undo step,
// applied to every selected object. A struct is fields, each a row with its
// own edit, unless a drawer draws it as one widget, the curve editor, a
// reference picker: that drawer calls edit_as_one_begin(ctx) and defers
// edit_as_one_end around its widgets, since the inspector cannot tell the two
// kinds of struct apart. A step that only adds rows around a drawing marks
// nothing.
//
// Odin has no closures, so the ctx carries the chain and a cursor instead
// of a captured continuation.

import "base:runtime"
import "core:reflect"
import "core:slice"
import core "moonhug:libs/core"
import "moonhug:libs/log"

ORDER_OUTER :: -1000 // outermost frames (headers, foldouts, banners)
ORDER_MIDDLE :: 0 // ordinary rows around the drawing
ORDER_INNER :: 1000 // the type's own drawing, closest to the default

// Everything a step knows about the value it draws.
Ctx :: struct {
	ptr:         rawptr,
	tid:         typeid,
	label:       cstring,
	path_prefix: string,
	// For an edit of the value as one row (edit_begin): the multi-edit offset
	// of the value inside the selected objects' copies, the field's name for
	// the undo step, and its property path for the override record.
	offset:      uintptr,
	name:        string,
	path:        string,
	// A field inside a struct, drawn by the field loop: the default drawing
	// of a struct value then puts its fields under a foldout, unless the
	// field is tagged inline. The foldout's context menu is drawn there too.
	nested:      bool,
	inline:      bool,
	menu_drawn:  bool,
	// Set while the value is an asset's import settings: the file, its guid,
	// the selected sub-asset. Zero for every other value.
	asset:       Asset_Info,
	_chain:      []Drawer,
	_index:      int,
}

Asset_Info :: struct {
	settings: bool, // the value is an asset's import settings
	path:     string,
	guid:     core.Asset_GUID,
	sub:      core.Local_ID, // the selected sub-asset (a model's part or clip), 0 = the asset itself
}

Drawer :: proc(ctx: ^Ctx)

// Step-facing: draw the value as everything beneath the calling step defines
// it — the rest of the chain, ending at the default drawing. Call it at most
// once.
draw :: proc(ctx: ^Ctx) {
	ctx._index += 1
	if ctx._index < len(ctx._chain) {
		ctx._chain[ctx._index](ctx)
	} else {
		_draw_end(ctx)
	}
}

// Host-facing: run the value through the funnel from the top (the whole
// chain, then the default drawing).
_funnel_draw :: proc(ctx: ^Ctx) {
	ctx._index = -1
	draw(ctx)
}

// Draws a value as a row, from the top of its chain: the entry for custom
// rows that pass a drawer to field_edit_row or property_row, and what
// resolve_property_drawer hands out.
draw_value :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	ctx := Ctx{ptr = ptr, tid = tid, label = label, name = string(label), _chain = _chain_of(tid)}
	_funnel_draw(&ctx)
}

// The chain's end: the default drawing for the kind of value.
@(private = "file")
_draw_end :: proc(ctx: ^Ctx) {
	if ctx.asset.settings {
		draw_default_import_settings()
		return
	}
	if reflect.is_struct(type_info_of(ctx.tid)) {
		draw_inspector_default(ctx.ptr, ctx.tid, ctx.label, ctx.path_prefix, ctx)
		return
	}
	draw_value_text(ctx.ptr, ctx.tid, ctx.label)
}

// --- Registration --------------------------------------------------------------

@(private = "file")
_Step :: struct {
	fn:     Drawer,
	order:  int,
	seq:    int,
	origin: string, // where it was declared, for debug tooltips
}

@(private = "file")
_steps: map[typeid][dynamic]_Step
@(private = "file")
_step_seq: int

// Declares a step of the chain for values of a type: how the type draws, or
// what sits around its drawing. `type` is the value's type, a container type
// expression included. `order` places the step, "outer", "middle" or "inner"
// or a number, lower outside; the type's own drawing, innermost, needs none.
// The generated register_property_drawers (property_drawer_gen) adds every
// declaration. Registry state never borrows the caller's allocator.
@(extension_point={attribute="property_drawer", target="proc", fields="type order"})
add_drawer :: proc(tid: typeid, fn: Drawer, order := ORDER_INNER, origin := "") {
	context.allocator = runtime.default_allocator()
	if _steps == nil do _steps = make(map[typeid][dynamic]_Step)
	if tid not_in _steps do _steps[tid] = make([dynamic]_Step)
	entries := &_steps[tid]
	_step_seq += 1
	append(entries, _Step{fn, order, _step_seq, origin})
	slice.sort_by(entries[:], proc(a, b: _Step) -> bool {
		return a.order < b.order || (a.order == b.order && a.seq < b.seq)
	})
}


// True when at least one step is registered for the type.
has_drawer :: proc(tid: typeid) -> bool {
	entries, ok := _steps[tid]
	return ok && len(entries) > 0
}

// Where the type's innermost step was declared, "" for none. The field row
// shows it in debug tooltips, since that step owns the row.
drawer_origin :: proc(tid: typeid) -> string {
	entries, ok := _steps[tid]
	if !ok || len(entries) == 0 do return ""
	return entries[len(entries) - 1].origin
}

// Drops every step and value declaration (tests).
drawers_reset :: proc() {
	for _, entries in _steps do delete(entries)
	delete(_steps)
	_steps = nil
	delete(_unmarked)
	_unmarked = nil
}

// Runs a leaf value's chain and reports, once per type, a step that changed
// the value without opening an edit: such a change records no undo and
// reaches no peer. `edits` and `changed` are _edit_count and
// inspector_changed from before the chain ran.
edit_check :: proc(ctx: ^Ctx, edits_before: int, changed_before: bool) {
	if reflect.is_struct(type_info_of(ctx.tid)) do return
	if !inspector_changed || changed_before || _edit_count != edits_before do return
	if ctx.tid in _unmarked do return
	context.allocator = runtime.default_allocator()
	_unmarked[ctx.tid] = true
	log.errorf("inspector: a @(property_drawer) step on %v changed the value without edit_begin/edit_end, so the change records no undo and reaches no other selected object (%s)", ctx.tid, drawer_origin(ctx.tid))
}

@(private = "file")
_unmarked: map[typeid]bool

// --- Chain build ---------------------------------------------------------------
// Built per draw into the temp allocator — registration order stays
// irrelevant to composition.

_chain_of :: proc(tid: typeid) -> []Drawer {
	entries, ok := _steps[tid]
	if !ok || len(entries) == 0 do return nil
	out := make([]Drawer, len(entries), context.temp_allocator)
	for e, i in entries do out[i] = e.fn
	return out
}
