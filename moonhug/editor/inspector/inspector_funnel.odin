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
// - anything else: the kind's own row, the same the field loop draws for a
//   type without steps (draw_kind_default): an enum combo, an array's list,
//   a union's variant picker, a pointer's target, or the value's text.
//
// Edits (field_edit.odin). A row of the inspector, a field or an array
// element, marks its ctx with `_row`. On a row, the inspector opens the edit
// around the chain for a leaf value, one that is always one row (is_row_kind):
// a number, a string, an enum, a bit set, a fixed array of numbers. One undo
// step, applied to every selected object. A container, a struct, a dynamic
// array, a union, a pointer, draws as rows of its own, each with its edit,
// unless a drawer draws it as one widget, the curve editor, a reference
// picker, the material's property list: that drawer calls
// edit_as_one_begin(ctx) and defers edit_as_one_end around its widgets, since
// the inspector cannot tell the two apart. Off a row (a bare draw_value from
// custom code, which runs its own edits or none), the pair does nothing. A
// step that only adds rows around a drawing marks nothing.
//
// Odin has no closures, so the ctx carries the chain and a cursor instead
// of a captured continuation.

import "base:runtime"
import "core:reflect"
import "core:slice"
import core "moonhug:libs/core"
import "moonhug:libs/log"
import undo "moonhug:editor/undo"

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
	// A row of the inspector drew this value: edits open (see above). Set by
	// the field loop and the array element path, never by draw_value.
	_row:        bool,
	// An array element: the default drawing of a struct marks its fields as
	// inside one, for inspector buttons with show_in_array=false.
	_element:    bool,
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
	draw_kind_default(ctx)
}

// True for a leaf value, always drawn as one row: the inspector opens its edit
// on a row. A number, a boolean, a string, a rune, an enum, a bit set, a type
// id, or a fixed array of numbers (a vector, a color, a guid), which multi-edit
// applies component by component. Everything else is a container, drawn as
// rows of its own unless a drawer edits it as one.
is_row_kind :: proc(tid: typeid) -> bool {
	ti := runtime.type_info_base(type_info_of(tid))
	#partial switch v in ti.variant {
	case runtime.Type_Info_Integer, runtime.Type_Info_Float, runtime.Type_Info_Boolean,
	     runtime.Type_Info_String, runtime.Type_Info_Rune, runtime.Type_Info_Enum,
	     runtime.Type_Info_Bit_Set, runtime.Type_Info_Type_Id:
		return true
	case runtime.Type_Info_Array:
		elem := runtime.type_info_base(v.elem)
		#partial switch _ in elem.variant {
		case runtime.Type_Info_Integer, runtime.Type_Info_Float:
			return true
		}
	}
	return false
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
// Each type's steps as the chain a draw walks, rebuilt when a step is added,
// so a draw allocates nothing.
@(private = "file")
_chains: map[typeid][]Drawer
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
	if _chains == nil do _chains = make(map[typeid][]Drawer)
	if old, has := _chains[tid]; has do delete(old)
	chain := make([]Drawer, len(entries))
	for e, i in entries do chain[i] = e.fn
	_chains[tid] = chain
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

// Drops every step (tests).
drawers_reset :: proc() {
	// The registry lives on the default allocator (add_drawer), whoever calls.
	context.allocator = runtime.default_allocator()
	for _, entries in _steps do delete(entries)
	delete(_steps)
	_steps = nil
	for _, chain in _chains do delete(chain)
	delete(_chains)
	_chains = nil
	delete(_unmarked)
	_unmarked = nil
}

// What edit_check compares around a container's chain on a row.
Edit_Probe :: struct {
	edits:     int,
	mutations: u64,
	changed:   bool,
}

edit_probe :: proc() -> Edit_Probe {
	return {edits = _edit_count, mutations = undo.mutation_count(), changed = inspector_changed}
}

// After a container's chain ran on a row, without an edit around it: reports,
// once per type, a change of the value that nothing recorded. No row edit
// opened inside, and no undo entry landed (an array's add and remove buttons
// record their own). A drawer that draws the container as one widget without
// edit_as_one_begin and edit_as_one_end does that, and its change records no
// undo and reaches no other selected object.
edit_check :: proc(ctx: ^Ctx, before: Edit_Probe) {
	if !inspector_changed || before.changed do return
	if _edit_count != before.edits || undo.mutation_count() != before.mutations do return
	if ctx.tid in _unmarked do return
	context.allocator = runtime.default_allocator()
	_unmarked[ctx.tid] = true
	log.errorf("inspector: a @(property_drawer) step on %v changed the value with nothing recorded: a drawer that draws it as one widget calls edit_as_one_begin(ctx) and defers edit_as_one_end around its widgets, or the change records no undo and reaches no other selected object (%s)", ctx.tid, drawer_origin(ctx.tid))
}

@(private = "file")
_unmarked: map[typeid]bool

// The type's chain, outermost step first. Read only: draws share it.
_chain_of :: proc(tid: typeid) -> []Drawer {
	return _chains[tid] or_else nil
}
