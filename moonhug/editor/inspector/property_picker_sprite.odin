package inspector

// Reusable Sprite object row (Unity's sprite picker): the reference is
// PPtr{texture guid, slice id 0 = whole texture}, the row shows
// "texture/slice", the popup lists every pickable sprite flat (Single-mode
// textures as their one sprite, sliced textures contributing their slices),
// and the field accepts texture drops (whole) and ASSET_PPTR sub-asset drops
// (exact slice). Slices are engine data (TextureSettings), so any package's
// editor half can use this row — SpriteRenderer and ParticleSystem do.
//
// Returns changed=true after writing `ref` — the caller commits (undo mark +
// override recording with its own property path).

import "core:encoding/uuid"
import "core:fmt"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "../../engine"

_SPRITE_REF_EXTS := [?]string{".png", ".jpg", ".jpeg", ".bmp"}

_sprite_ref_is_texture :: proc(path: string) -> bool {
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	for e in _SPRITE_REF_EXTS do if ext == e do return true
	return false
}

sprite_ref_display :: proc(ref: engine.PPtr) -> string {
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

sprite_ref_row :: proc(label: cstring, ref: ^engine.PPtr) -> (changed: bool) {
	has_value := !engine.asset_guid_is_empty(ref.guid)
	display := sprite_ref_display(ref^)

	value_clicked, value_double, cleared: bool
	dropped: string
	dropped_ref: engine.PPtr
	dropped_ref_ok: bool
	popup_id := fmt.ctprintf("sprite_ref_picker##%s", label)
	if _picker_field_row(label, display, has_value, &value_clicked, &cleared, &value_double, &dropped, &dropped_ref, &dropped_ref_ok) {
		im.OpenPopup(popup_id)
	}
	if value_clicked && has_value {
		engine.inspector_request_ping_asset(ref.guid)
	}
	if cleared {
		ref^ = {}
		changed = true
	}
	// A texture drop assigns its whole-texture sprite, a sub-asset drop (a
	// slice row from the project window) the exact slice.
	if dropped != "" && _sprite_ref_is_texture(dropped) {
		if guid, gok := engine.asset_db_get_guid(dropped); gok {
			ref^ = engine.PPtr{guid = engine.Asset_GUID(guid)}
			changed = true
		}
	}
	if dropped_ref_ok {
		if path, pok := engine.asset_db_get_path(uuid.Identifier(dropped_ref.guid)); pok && _sprite_ref_is_texture(path) {
			ref^ = dropped_ref
			changed = true
		}
	}

	if im.BeginPopup(popup_id) {
		search := _picker_search_bar()
		if im.Selectable("None") {
			ref^ = {}
			changed = true
		}
		im.Separator()
		if picked, ok := _sprite_ref_rows(search, ref^); ok {
			ref^ = picked
			changed = true
		}
		im.EndPopup()
	}
	return changed
}

// Every pickable sprite, "texture" or "texture/slice", name-filtered.
// Row IDs scope by list ORDER, never by the reference — pre-heal metas carry
// id 0 on every slice, and an id-0 slice reference MEANS the whole texture,
// so those are skipped rather than listed wrong.
@(private = "file")
_sprite_ref_rows :: proc(search: string, current: engine.PPtr) -> (picked: engine.PPtr, ok: bool) {
	row :: proc(label: string, ref: engine.PPtr, current: engine.PPtr, search: string, shown: ^int, picked: ^engine.PPtr, ok: ^bool) {
		if search != "" && !strings.contains(strings.to_lower(label, context.temp_allocator), search) do return
		shown^ += 1
		c_label := strings.clone_to_cstring(fmt.tprintf("%s##row_%d", label, shown^), context.temp_allocator)
		if im.Selectable(c_label, ref == current) {
			picked^ = ref
			ok^ = true
		}
	}

	paths := make([dynamic]string, context.temp_allocator)
	for path in engine.asset_db.path_to_guid {
		if _sprite_ref_is_texture(path) do append(&paths, path)
	}
	slice.sort(paths[:])

	shown := 0
	for path in paths {
		guid, _ := engine.asset_db_get_guid(path)
		base := filepath.stem(filepath.base(path))
		tex, tok := engine.texture_load(engine.Asset_GUID(guid))
		listed := false
		if tok {
			for s in tex.sprites {
				if s.id == 0 do continue
				listed = true
				label := fmt.tprintf("%s/%s", base, s.name)
				row(label, engine.PPtr{guid = engine.Asset_GUID(guid), local_id = s.id}, current, search, &shown, &picked, &ok)
			}
		}
		if !listed {
			row(base, engine.PPtr{guid = engine.Asset_GUID(guid)}, current, search, &shown, &picked, &ok)
		}
	}
	if shown == 0 do im.TextDisabled("(no matches)")
	return picked, ok
}
