package app_editor

import sprites "moonhug:packages/sprites"
import log "moonhug:libs/log"

// A drawer example, commented out: this package cannot import the inspector,
// which imports it back for its @(context_menu) procs. A drawer lives in a
// package the inspector does not import. With it, every ButtonsExample draws
// as this one line instead of its fields:
//
//   @(property_drawer={type=app.ButtonsExample})
//   property_drawer_ButtonsExample :: proc(ctx: ^inspector.Ctx) {
//       im.Text(fmt.ctprintf("Hello, %s", ctx.label))
//   }

@(context_menu={type=sprites.SpriteRenderer, menu="Log Sprite Values", order=-100})
log_sprite_values :: proc(comp_ptr: rawptr) {
    sprite := cast(^sprites.SpriteRenderer)comp_ptr
    log.infof("Sprite color: [%.2f, %.2f, %.2f, %.2f], enabled: %v",
        sprite.color[0], sprite.color[1], sprite.color[2], sprite.color[3], sprite.enabled)
}

