package inspector

// Example :: struct{
//    field1:int `
//        decor:header(name="Hello") // <-- decorator_header :: proc(ctx:^DrawContext, name:string)
//        decor:separator()`,        // <-- decorator_separator :: proc(ctx:^DrawContext)
//}

DecoratorProc :: distinct proc(ctx: ^DrawContext)
DecoratorsMap :: map[typeid][]DecoratorProc

decorator_registry: DecoratorsMap

DrawContext :: struct {
    is_visible: bool,
    is_pre:     bool,
    field_ptr:  rawptr,
    field_type: typeid,
    field_label: cstring,
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
    run(ctx)
}
