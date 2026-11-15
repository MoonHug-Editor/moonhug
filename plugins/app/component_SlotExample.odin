package app

// Slots example: an object whose height offset and size are slots
// (moonhug/libs/slots). Each is set in the inspector, or connected there to
// an entry the game fills. The entries are declared and filled below, in the
// game-wide dictionary.

import "base:runtime"
import "core:math"
import "moonhug:libs/slots"
import "moonhug:libs/time"
import "moonhug:packages/engine"

@(component={menu="Demo/SlotExample"})
@(typ_guid={guid = "7c381d68-a8b8-4dc9-8496-8d6fe8d49e74"})
SlotExample :: struct {
    using base: engine.CompData `inspect:"-"`,
    // Added to where the object stands.
    offset:  slots.Slot,
    _offset: [3]f32 `inspect:"-"`,
    // The object's size on every axis.
    size:  slots.Slot,
    _size: f32 `inspect:"-" decor:min(0)`,

    home: [3]f32 `json:"-" inspect:"-"`,
}

type_reset_SlotExample :: proc(comp: ^SlotExample) {
    comp._size = 1
}

@(comp_awake={component=SlotExample})
comp_awake_SlotExample :: proc(comp: ^SlotExample) {
    if t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(comp.owner)); t != nil do comp.home = t.position
}

// Read every frame, so a connected slot follows its entry.
@(comp_update={component=SlotExample})
comp_update_SlotExample :: proc(dt: f32, comp: ^SlotExample) {
    t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(comp.owner))
    if t == nil do return
    t.position = comp.home + slots.get(comp.offset, comp._offset, slots.global())
    size := slots.get(comp.size, comp._size, slots.global())
    t.scale = {size, size, size}
}

// What the game offers to slots: declared, so the inspector lists them, and
// filled in the game-wide dictionary.
@(init)
_slot_example_entries :: proc "contextless" () {
    context = runtime.default_context()
    slots.declare("demo_bob", [3]f32, "Up and down, one unit, once every two seconds")
    slots.declare("demo_pulse", f32, "Between 0.5 and 1.5, once a second")
    slots.declare("demo_double", f32, "Always 2")
    slots.set_proc(slots.global(), "demo_bob", [3]f32, proc(out: ^[3]f32, user: rawptr) {
        out^ = {0, f32(abs(math.sin(time.now() * math.PI * 0.5))), 0}
    })
    slots.set_proc(slots.global(), "demo_pulse", f32, proc(out: ^f32, user: rawptr) {
        out^ = f32(1 + 0.5 * math.sin(time.now() * math.TAU))
    })
    slots.set(slots.global(), "demo_double", f32(2))
}
