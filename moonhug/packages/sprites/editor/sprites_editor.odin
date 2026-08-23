package sprites_editor

// Editor-only half of the sprites package: compiled into the editor binary,
// never the app. May import engine, imgui and the editor's subpackages —
// never the editor root (docs/Plugins.md layering rule).

import "core:fmt"
import "core:strings"
import "moonhug:engine"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/inspector"
import sprites "moonhug:packages/sprites"

@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
sprites_inspector_install :: proc() {
	inspector.add_component_wrapper(typeid_of(sprites.SpriteRenderer), _sprite_renderer_inspector)
}

// Default fields, then a Sprite dropdown when the texture carries slices
// (sprite_mode = Multiple). The `sprite` field itself is inspect:"-" — this
// row is its only editor, Unity's sprite object picker shape.
_sprite_renderer_inspector :: proc(ctx: ^inspector.Component_Ctx) {
	inspector.draw(ctx)
	sr := cast(^sprites.SpriteRenderer)ctx.ptr

	tex, ok := engine.texture_load(sr.texture)
	if !ok || len(tex.sprites) == 0 do return

	preview := sr.sprite == "" ? "(whole texture)" : sr.sprite
	// A stale name (slice renamed or removed) draws nothing — say so.
	if sr.sprite != "" {
		if _, found := engine.texture_sprite_rect(tex, sr.sprite); !found {
			preview = fmt.tprintf("%s (missing)", sr.sprite)
		}
	}

	if im.BeginCombo("Sprite", strings.clone_to_cstring(preview, context.temp_allocator)) {
		if im.Selectable("(whole texture)", sr.sprite == "") {
			_set_sprite(sr, "")
		}
		for s in tex.sprites {
			if im.Selectable(strings.clone_to_cstring(s.name, context.temp_allocator), sr.sprite == s.name) {
				_set_sprite(sr, s.name)
			}
		}
		im.EndCombo()
	}
}

_set_sprite :: proc(sr: ^sprites.SpriteRenderer, name: string) {
	if sr.sprite == name do return
	delete(sr.sprite)
	sr.sprite = strings.clone(name)
	inspector.mark_inspector_changed()
	inspector.record_nested_override(&sr.sprite, typeid_of(string), "sprite", true)
}
