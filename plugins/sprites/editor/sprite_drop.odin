package sprites_editor

// What a sprite or a texture dropped into the scene becomes
// (scene_tools.asset_drop): an object with a SpriteRenderer drawing it.

import "core:encoding/uuid"
import "core:path/filepath"
import "moonhug:packages/engine"
import sprites "moonhug:packages/sprites"

// A slice of a texture becomes an object drawing it, named after it.
@(asset_on_drop={kind="sprite"})
asset_on_drop_sprite :: proc(ref: engine.PPtr, parent: engine.Transform_Handle) -> engine.Transform_Handle {
	name := "Sprite"
	for s in engine.asset_db_sub_assets(ref.guid) do if s.id == ref.local_id && s.name != "" do name = s.name
	return _sprite_object(name, ref, parent)
}

// A texture becomes an object drawing it, named after the file: the whole
// texture, or its first slice when it is sliced (sprite_mode Multiple).
@(asset_on_drop={kind="png jpg jpeg bmp"})
asset_on_drop_texture :: proc(ref: engine.PPtr, parent: engine.Transform_Handle) -> engine.Transform_Handle {
	path, ok := engine.asset_db_get_path(uuid.Identifier(ref.guid))
	if !ok do return {}
	sprite := engine.PPtr{guid = ref.guid}
	if settings, sok := engine.asset_pipeline_get_settings(path, context.temp_allocator); sok {
		if ts, is_texture := settings.(engine.TextureSettings); is_texture && ts.sprite_mode == .Multiple {
			// A slice with no id yet cannot be referenced.
			for s in ts.sprites do if s.id != 0 {
				sprite.local_id = s.id
				break
			}
		}
	}
	return _sprite_object(filepath.stem(path), sprite, parent)
}

@(private = "file")
_sprite_object :: proc(name: string, sprite: engine.PPtr, parent: engine.Transform_Handle) -> engine.Transform_Handle {
	tH := engine.transform_new(name, parent)
	_, raw := engine.transform_add_comp(tH, .SpriteRenderer)
	(cast(^sprites.SpriteRenderer)raw).sprite = sprite
	return tH
}
