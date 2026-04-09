package engine

import "core:reflect"
import "core:encoding/json"

TweenStatus :: enum { Pending, Running, Done }
TweenContext :: struct {
    subject: Transform_Handle `json:"-"`,
}
TweenTickProc :: proc(task:^TweenUnion, delta_time:f32, ctx:TweenContext) -> TweenStatus
TweenFreeProc :: proc(^TweenUnion)
tween_free_procs: [TypeKey]TweenFreeProc
tween_tick_procs: [TypeKey]TweenTickProc

// Hierarchical Task
@(typ_guid={guid="aecaf150-0418-4fed-81a3-708f68ccaa8b"})
Tween :: struct {
    skip:bool,
    is_await:bool,
    delay:f32,
    subject: Ref,

    // runtime only fields:
    delay_elapsed:f32 `json:"-"`,
    status: TweenStatus `json:"-"`,
}

tween_base :: proc(task: ^TweenUnion) -> ^Tween {
    return cast(^Tween)task
}

tick_Tween :: proc(task:^TweenUnion, delta_time:f32, ctx:TweenContext) -> TweenStatus {
    return .Done
}

_tween_tick_child :: proc(task: ^TweenUnion, delta_time: f32, ctx: TweenContext) -> TweenStatus {
    tid := reflect.union_variant_typeid(task^)
    if tid == nil do return .Done
    base := tween_base(task)
    if base.skip do return .Done
    key    := typeid_to_type_key_map[tid]
    tick := tween_tick_procs[key]
    if tick == nil do return .Done
    return tick(task, delta_time, ctx)
}

tween_has_delay :: proc(base: ^Tween, delta_time: f32) -> bool {
    if base.delay_elapsed < base.delay {
        base.delay_elapsed += delta_time
        return true
    }
    return false
}

// --- Tween runtime ticking

tween_lib : map[string][]byte

TweenRunning :: struct {
    data : TweenUnion,
    ctx  : TweenContext,
    next : ^TweenRunning,
    prev : ^TweenRunning,
}

tween_init :: proc() {
    tween_lib = make(map[string][]byte)
    __tween_ticks_init()
}

tween_register :: proc(key: string, tween: ^TweenUnion) {
    if key in tween_lib {
        //log.error("Tween is already registered: ''")
        return
    }
    data, err := json.marshal(tween^)
    if err != nil do return
    tween_lib[key] = data
}

tween_running_head : ^TweenRunning

tween_run :: proc { tween_run_key, tween_run_tween }

tween_run_key :: proc(key: string, ctx: TweenContext) -> bool {
    raw, ok := tween_lib[key]
    if !ok do return false

    node := new(TweenRunning)
    if err := json.unmarshal(raw, &node.data); err != nil {
        free(node)
        return false
    }
    return tween_run_internal(node, ctx)
}

tween_run_tween :: proc(tween: ^TweenUnion, ctx: TweenContext) -> bool {
    node := new(TweenRunning)
    node.data = tween^
    return tween_run_internal(node, ctx)
}

tween_run_internal :: proc(node: ^TweenRunning, ctx: TweenContext) -> bool {
    if tween_base(&node.data).skip {
        tween_free(&node.data)
        free(node)
        return false
    }
    node.ctx = ctx
    node.next = tween_running_head
    if tween_running_head != nil do tween_running_head.prev = node
    tween_running_head = node
    return true
}

tween_free :: proc(task : ^TweenUnion) {
    tid := reflect.union_variant_typeid(task^)
    if tid == nil do return
    key    := typeid_to_type_key_map[tid]
    free_proc := tween_free_procs[key]
    if free_proc != nil do free_proc(task)
}

tween_tick_running :: proc(delta_time: f32, ctx: TweenContext) {
    node := tween_running_head
    for node != nil {
        next := node.next
        status := _tween_tick_child(&node.data, delta_time, node.ctx)
        if status == .Done {
        // unlink
            if node.prev != nil do node.prev.next = node.next
            if node.next != nil do node.next.prev = node.prev
            if tween_running_head == node do tween_running_head = node.next
            tween_free(&node.data)
            free(node)
        }
        node = next
    }
}

