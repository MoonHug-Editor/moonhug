package engine

import gfx "moonhug:host/gfx"
import "base:runtime"
import "core:encoding/uuid"
import "core:strings"

// GUID-keyed texture cache. The GPU side lives in ^gfx.Texture, which is
// heap-allocated by gfx (its embedded imgui binding address must stay stable).
Texture2D :: struct {
    guid:   Asset_GUID,
    width:  i32,
    height: i32,
    // From the texture's import settings (Unity's Pixels Per Unit): sprite
    // world size = pixel size / this. Always > 0.
    pixels_per_unit: f32,
    // Slices from the import settings (sprite_mode = Multiple), cache-owned
    // clones. Empty for Single-mode textures.
    sprites: []Sprite_Rect,
    // Single mode's 9-slice borders (TextureSettings.sprite_border), pixels.
    border: [4]f32,
    gfx:    ^gfx.Texture,
}

// Slice lookup by persistent id; slice counts are small, linear scan.
texture_sprite_rect :: proc(tex: ^Texture2D, id: Local_ID) -> (Sprite_Rect, bool) {
    for s in tex.sprites {
        if s.id == id do return s, true
    }
    return {}, false
}

// Cache-owned slice memory lives on the process heap: texture_load runs
// under arbitrary context allocators (render-pass temp included), so the
// clones and their frees pin the allocator explicitly.
_texture_sprites_free :: proc(tex: ^Texture2D) {
    alloc := runtime.default_allocator()
    for s in tex.sprites do delete(s.name, alloc)
    delete(tex.sprites, alloc)
    tex.sprites = nil
}

texture_cache: map[Asset_GUID]Texture2D

texture_cache_init :: proc() {
    texture_cache = make(map[Asset_GUID]Texture2D)
    // Cached textures bake pixels_per_unit at load — evict on reimport so
    // new settings apply without a restart.
    @(static) hooked := false
    if !hooked {
        hooked = true
        asset_pipeline_add_reimport_hook(texture_unload)
    }
}

texture_cache_shutdown :: proc() {
    for _, &tex in texture_cache {
        _texture_sprites_free(&tex)
        gfx.texture_destroy(tex.gfx)
    }
    delete(texture_cache)
}

texture_load :: proc(guid: Asset_GUID) -> (^Texture2D, bool) {
    if tex, ok := &texture_cache[guid]; ok {
        return tex, true
    }
    // Headless contexts (tests, scene tooling) have no GPU device.
    if gfx.device() == nil do return nil, false

    // Artifact first, like every other loader: the artifact is what an export
    // ships (catalog.export_from copies no source for an imported asset), so
    // reading the source first would work in the editor and fail in a build.
    // The source is the fallback for a dev run whose import has not happened.
    // The path stays the key for settings even when the file is not there.
    path, path_ok := asset_db_get_path(uuid.Identifier(guid))
    if !path_ok do return nil, false
    artifact := _artifact_path(uuid.Identifier(guid))
    defer delete(artifact)
    g := gfx.texture_decode_file(artifact)
    if g == nil do g = gfx.texture_decode_file(path)
    if g == nil do return nil, false

    ppu := f32(PIXELS_PER_UNIT)
    sprites: []Sprite_Rect
    border: [4]f32
    if settings, sok := asset_pipeline_get_settings(path, context.temp_allocator); sok {
        if ts, is_tex := settings.(TextureSettings); is_tex {
            if ts.pixels_per_unit > 0 do ppu = ts.pixels_per_unit
            border = ts.sprite_border
            // Settings live on the temp allocator — the cache owns clones
            // (_texture_sprites_free frees them, same pinned allocator).
            if ts.sprite_mode == .Multiple && len(ts.sprites) > 0 {
                alloc := runtime.default_allocator()
                sprites = make([]Sprite_Rect, len(ts.sprites), alloc)
                for s, i in ts.sprites {
                    sprites[i] = s
                    sprites[i].name = strings.clone(s.name, alloc)
                }
            }
        }
    }

    texture_cache[guid] = Texture2D{
        guid   = guid,
        width  = g.width,
        height = g.height,
        pixels_per_unit = ppu,
        sprites = sprites,
        border = border,
        gfx    = g,
    }
    return &texture_cache[guid], true
}

texture_unload :: proc(guid: Asset_GUID) {
    if tex, ok := &texture_cache[guid]; ok {
        _texture_sprites_free(tex)
        gfx.texture_destroy(tex.gfx)
        delete_key(&texture_cache, guid)
    }
}

