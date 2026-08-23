package sprites_editor

// Editor-only half of the sprites package: compiled into the editor binary,
// never the app. May import engine, imgui and the editor's subpackages —
// never the editor root (docs/Plugins.md layering rule).

import "core:encoding/uuid"
import "core:fmt"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "moonhug:engine"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/inspector"
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
}

// The display name for a sprite reference — the reference itself is
// PPtr{texture guid, slice id}, the name is a view detail.
_sprite_display :: proc(ref: engine.PPtr) -> string {
	if engine.asset_guid_is_empty(ref.guid) do return "None"
	path, pok := engine.asset_db_get_path(uuid.Identifier(ref.guid))
	if !pok do return fmt.tprintf("%v", ref.guid)
	base := filepath.stem(filepath.base(path))
	if ref.local_id == 0 do return base
	if tex, tok := engine.texture_load(ref.guid); tok {
		if s, found := engine.texture_sprite_rect(tex, ref.local_id); found {
			return fmt.tprintf("%s/%s", base, s.name)
		}
	}
	return fmt.tprintf("%s/(missing)", base)
}

// Default fields, then the Sprite object row — Unity's sprite picker: a flat
// list of every pickable sprite (Single-mode textures as their one sprite,
// Multiple-mode textures contributing their slices). Dropping a texture
// assigns its whole-texture sprite. The `sprite` field itself is inspect:"-"
// — this row is its only editor.
_sprite_renderer_inspector :: proc(ctx: ^inspector.Component_Ctx) {
	inspector.draw(ctx)
	sr := cast(^sprites.SpriteRenderer)ctx.ptr

	has_value := !engine.asset_guid_is_empty(sr.sprite.guid)
	display := _sprite_display(sr.sprite)

	value_clicked, value_double, cleared: bool
	dropped: string
	if inspector._picker_field_row("Sprite", display, has_value, &value_clicked, &cleared, &value_double, &dropped) {
		im.OpenPopup("sprite_picker")
	}
	if value_clicked && has_value {
		engine.inspector_request_ping_asset(sr.sprite.guid)
	}
	if cleared {
		_set_sprite(sr, {})
	}
	if dropped != "" && _is_texture_path(dropped) {
		if guid, gok := engine.asset_db_get_guid(dropped); gok {
			_set_sprite(sr, engine.PPtr{guid = engine.Asset_GUID(guid)})
		}
	}

	if im.BeginPopup("sprite_picker") {
		search := inspector._picker_search_bar()
		if im.Selectable("None") {
			_set_sprite(sr, {})
		}
		im.Separator()
		if picked, ok := _sprite_picker_rows(search, sr.sprite); ok {
			_set_sprite(sr, picked)
		}
		im.EndPopup()
	}
}

// Every pickable sprite, "texture" or "texture/slice", name-filtered.
_sprite_picker_rows :: proc(search: string, current: engine.PPtr) -> (picked: engine.PPtr, ok: bool) {
	paths := make([dynamic]string, context.temp_allocator)
	for path in engine.asset_db.path_to_guid {
		if _is_texture_path(path) do append(&paths, path)
	}
	slice.sort(paths[:])

	shown := 0
	for path in paths {
		guid, _ := engine.asset_db_get_guid(path)
		base := filepath.stem(filepath.base(path))
		row :: proc(label: string, ref: engine.PPtr, current: engine.PPtr, search: string, shown: ^int, picked: ^engine.PPtr, ok: ^bool) {
			if search != "" && !strings.contains(strings.to_lower(label, context.temp_allocator), search) do return
			shown^ += 1
			c_label := strings.clone_to_cstring(fmt.tprintf("%s##%v_%d", label, ref.guid, ref.local_id), context.temp_allocator)
			if im.Selectable(c_label, ref == current) {
				picked^ = ref
				ok^ = true
			}
		}

		tex, tok := engine.texture_load(engine.Asset_GUID(guid))
		if tok && len(tex.sprites) > 0 {
			for s in tex.sprites {
				label := fmt.tprintf("%s/%s", base, s.name)
				row(label, engine.PPtr{guid = engine.Asset_GUID(guid), local_id = s.id}, current, search, &shown, &picked, &ok)
			}
		} else {
			row(base, engine.PPtr{guid = engine.Asset_GUID(guid)}, current, search, &shown, &picked, &ok)
		}
	}
	if shown == 0 do im.TextDisabled("(no matches)")
	return picked, ok
}

_set_sprite :: proc(sr: ^sprites.SpriteRenderer, ref: engine.PPtr) {
	if sr.sprite == ref do return
	sr.sprite = ref
	inspector.mark_inspector_changed()
	inspector.record_nested_override(&sr.sprite, typeid_of(engine.PPtr), "sprite", true)
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
