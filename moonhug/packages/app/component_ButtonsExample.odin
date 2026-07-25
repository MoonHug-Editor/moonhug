package app

// Inspector action-button showcase. Add via Component menu:
// Examples/Buttons Example. Every press logs a [btn] line to the console, so
// placement, ordering, weights, arity dispatch and undo are all observable.
//
// Expected inspector layout, top to bottom:
//   Ping Top                       (component row 1)
//   Count++ | Reset Count          (component row 0, weights 2:1)
//   counter field
//   [ Row 2 ]                      (field row 2)
//   [ Wide w=3 | w=1 ]             (field row 1)
//   [ No Args ]                    (field row 0, proc() form)
//   target field
//   [ Clear (below) ]              (field row -1, 2-arg form)
//   item (nested struct)           (framed by BOTH "Log Item" and
//                                   "Only Standalone" — not an array element)
//   items array                    (each element framed by "Log Item" only;
//                                   show_in_array=false hides per element)
//   Log State                      (component row -1)

import "moonhug:engine"
import "moonhug:engine/log"

@(component={menu="Examples/Buttons Example"})
@(typ_guid={guid = "c9fc78b6-6022-4723-8dea-6b2544b6480d"})
ButtonsExample :: struct {
    using base: engine.CompData `inspect:"-"`,
    counter: int,
    target:  engine.Ref_Local `ref:"Transform"
        decor:button(be_row2, label="Row 2", row=2)
        decor:button(be_wide, label="Wide w=3", row=1, weight=3)
        decor:button(be_narrow, label="w=1", row=1)
        decor:button(be_no_args, label="No Args", row=0)
        decor:button(be_clear_target, label="Clear (below)", row=-1)`,
    item:    Button_Item,
    items:   [dynamic]Button_Item,
}

Button_Item :: struct {
    name:  string,
    value: f32,
}

reset_ButtonsExample :: proc(comp: ^ButtonsExample) {
}

// --- field buttons (decor:button on `target`) ------------------------------

be_row2 :: proc(b: ^ButtonsExample) {
    log.infof("[btn] Row 2: 1-arg form, counter=%d", b.counter)
}

be_wide :: proc(b: ^ButtonsExample) {
    log.infof("[btn] Wide (weight=3): counter=%d", b.counter)
}

be_narrow :: proc(b: ^ButtonsExample) {
    log.infof("[btn] narrow (weight=1): counter=%d", b.counter)
}

be_no_args :: proc() {
    log.info("[btn] No Args: 0-arg form — the field only anchors placement")
}

// 2-arg form receives &b.target (the tagged field). Mutates → one undo step.
be_clear_target :: proc(b: ^ButtonsExample, target: ^engine.Ref_Local) {
    log.infof("[btn] Clear (below): 2-arg form, target was lid=%d — undoable", target.local_id)
    target^ = {}
}

// --- component buttons (@(inspector_button)) -------------------------------

@(inspector_button={label="Ping Top", row=1})
be_ping :: proc(b: ^ButtonsExample) {
    log.infof("[btn] Ping Top: component row=1, lid=%d", b.local_id)
}

@(inspector_button={label="Count++", row=0, weight=2})
be_count_up :: proc(b: ^ButtonsExample) {
    b.counter += 1
    log.infof("[btn] Count++: counter=%d — undoable", b.counter)
}

@(inspector_button={label="Reset Count", row=0})
be_count_reset :: proc(b: ^ButtonsExample) {
    b.counter = 0
    log.info("[btn] Reset Count: counter=0 — undoable")
}

@(inspector_button={label="Log State", row=-1})
be_log_state :: proc(b: ^ButtonsExample) {
    log.infof("[btn] Log State: bottom block, counter=%d target=%d items=%d",
        b.counter, b.target.local_id, len(b.items))
}

// --- array-element buttons (@(inspector_button) on the element type) -------
// "Log Item" frames every element of `items` (show_in_array defaults true);
// "Only Standalone" opts out and never appears inside the array.

@(inspector_button={label="Log Item"})
be_log_item :: proc(it: ^Button_Item) {
    log.infof("[btn] Log Item: name=%q value=%v", it.name, it.value)
}

@(inspector_button={label="Only Standalone", show_in_array=false})
be_item_standalone :: proc(it: ^Button_Item) {
    log.info("[btn] Only Standalone: visible only outside arrays")
}
