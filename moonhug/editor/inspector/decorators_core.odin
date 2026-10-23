package inspector

// Example :: struct{
//    field1:int `
//        decor:header(name="Hello") // <-- decorator_header :: proc(ctx:^DrawContext, name:string)
//        decor:separator()`,        // <-- decorator_separator :: proc(ctx:^DrawContext)
//}

import "moonhug:editor/widgets"

DecoratorProc :: distinct proc(ctx: ^DrawContext)
DecoratorsMap :: map[typeid][]DecoratorProc

decorator_registry: DecoratorsMap

// The `decor:` tags behind each entry of decorator_registry, indexed the same
// way (typeid, then field index). Filled by init_decorators; a field with no
// decorators has "".
decorator_origin_registry: map[typeid][]string

DrawContext :: struct {
    is_visible: bool,
    is_pre:     bool,
    handled_draw: bool,
    field_ptr:  rawptr,
    field_type: typeid,
    field_label: cstring,
    // The struct the field belongs to (the component for top-level fields, the
    // sub-struct when draw_inspector recurses). decorator_button invokes its
    // action against this.
    owner_ptr:  rawptr,
    owner_type: typeid,
}

// Whether the field shows in the inspector: drawn by the inspector's own
// drawer (is_visible), or by a decorator that draws it in its place, which
// clears is_visible so the drawer skips it and sets handled_draw. Only
// decor:hide clears both. A decorator that adds to the row (a help box, a
// tooltip, a header) checks this, so it stays on a field another decorator
// draws, a decor:range slider for one.
field_shown :: proc(ctx: ^DrawContext) -> bool {
    return ctx.is_visible || ctx.handled_draw
}

// inspector should run decorators in regular order for pre stage and in reverse order for post stage
// between pre and post stages if ctx.is_visible inspector should draw field itself
run_field_decorators :: proc(tid: typeid, field_index: int, ctx: ^DrawContext) {
    if ctx == nil do return
    decorators, ok := decorator_registry[tid]
    if !ok || decorators == nil do return
    if field_index < 0 || field_index >= len(decorators) do return
    run := decorators[field_index]
    if run == nil do return
    // A decorator draws part of the field's row, so its tag is what debug tooltips
    // names for anything it hovers. Popped before returning, so the row's own
    // drawer is not attributed to the decorator.
    origin := ""
    if origins, has := decorator_origin_registry[tid]; has && field_index < len(origins) {
        origin = origins[field_index]
    }
    prev := widgets.ui_origin_push(origin)
    defer widgets.ui_origin_pop(prev)
    run(ctx)
}
