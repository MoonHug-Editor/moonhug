package app_editor

import "core:fmt"
import "core:strings"
import im "../../external/odin-imgui"
import engine "../engine"
import log "../engine/log"

//@(property_drawer={type=app.A, priority = 10})
draw_A_property :: proc(ptr: rawptr, tid: typeid, label: cstring) {
    label2 := fmt.tprintf("Hello, %s", label);
    c_label: cstring = strings.clone_to_cstring(label2)
    defer delete(c_label)
    im.Text(c_label)
}

@(context_menu={type=engine.SpriteRenderer, menu="Log Sprite Values", order=-100})
log_sprite_values :: proc(comp_ptr: rawptr) {
    sprite := cast(^engine.SpriteRenderer)comp_ptr
    log.infof("Sprite color: [%.2f, %.2f, %.2f, %.2f], enabled: %v",
        sprite.color[0], sprite.color[1], sprite.color[2], sprite.color[3], sprite.enabled)
}

