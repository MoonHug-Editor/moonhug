package sprites_editor

// Editor-only half of the sprites package: compiled into the editor binary,
// never the app. May import engine, imgui and the editor's subpackages —
// never the editor root (docs/Plugins.md layering rule).

import "base:runtime"
import "core:encoding/uuid"
import "core:fmt"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "moonhug:engine"
import gfx "moonhug:engine/gfx"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/inspector"
import "moonhug:editor/subassets"
import sprites "moonhug:packages/sprites"

_TEXTURE_EXTS := [?]string{".png", ".jpg", ".jpeg", ".bmp"}

_is_texture_path :: proc(path: string) -> bool {
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	for e in _TEXTURE_EXTS do if ext == e do return true
	return false
}

@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
sprites_inspector_install :: proc() {
	inspector.add_component_wrapper(typeid_of(sprites.SpriteRenderer), _sprite_renderer_inspector)
	inspector.add_asset_wrapper("texture", _texture_slicer)
	// Project-window sub-assets: sliced textures unfold to their sprites.
	for ext in _TEXTURE_EXTS {
		subassets.register(ext, subassets.Provider{
			list = _texture_sub_assets,
			open = _open_sprite_editor_at,
		})
	}
}

_texture_sub_assets :: proc(path: string, allocator: runtime.Allocator) -> []subassets.Sub_Asset {
	guid, ok := engine.asset_db_get_guid(path)
	if !ok do return nil
	tex, tok := engine.texture_load(engine.Asset_GUID(guid))
	if !tok || len(tex.sprites) == 0 do return nil
	out := make([dynamic]subassets.Sub_Asset, 0, len(tex.sprites), allocator)
	tw, th := f32(tex.width), f32(tex.height)
	for s in tex.sprites {
		// Pre-heal slices (id 0) are unreferenceable — the Sprite Editor
		// shows and heals them, the project window skips them.
		if s.id == 0 do continue
		append(&out, subassets.Sub_Asset{
			id    = s.id,
			name  = s.name,
			image = gfx.texture_imgui_id(tex.gfx),
			uv0   = {s.rect.x / tw, s.rect.y / th},
			uv1   = {(s.rect.x + s.rect.z) / tw, (s.rect.y + s.rect.w) / th},
			size  = {s.rect.z, s.rect.w},
		})
	}
	return out[:]
}

_open_sprite_editor_at :: proc(path: string, guid: engine.Asset_GUID, id: engine.Local_ID) {
	sprite_editor_open_at(path, guid, id)
}

// Default fields, then the Sprite object row (inspector.sprite_ref_row —
// Unity's sprite picker, shared with the particles package). The `sprite`
// field itself is inspect:"-" — this row is its only editor.
_sprite_renderer_inspector :: proc(ctx: ^inspector.Component_Ctx) {
	inspector.draw(ctx)
	sr := cast(^sprites.SpriteRenderer)ctx.ptr
	if inspector.sprite_ref_row("Sprite", &sr.sprite) {
		inspector.mark_inspector_changed()
		inspector.record_nested_override(&sr.sprite, typeid_of(engine.PPtr), "sprite", true)
	}
}

// --- Asset funnel: the Sprite Editor button ----------------------------------
// Unity's shape: the texture importer inspector carries a Sprite Editor
// button, the slicing itself happens in the dedicated window
// (sprite_editor_window.odin) with its own Apply/Revert.
_texture_slicer :: proc(ctx: ^inspector.Asset_Ctx) {
	inspector.draw(ctx) // Apply + the reflected TextureSettings

	if ctx.settings.id != typeid_of(engine.TextureSettings) do return
	ts := cast(^engine.TextureSettings)ctx.settings.data

	im.Separator()
	if im.Button("Sprite Editor") {
		sprite_editor_open(ctx.path, ctx.guid)
	}
	if ts.sprite_mode == .Multiple {
		im.SameLine()
		im.TextDisabled("%d slices", i32(len(ts.sprites)))
	}
}
