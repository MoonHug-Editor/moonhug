package engine

import gfx "gfx"
import stbi "vendor:stb/image"
import "core:encoding/uuid"
import "core:os"
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
    gfx:    ^gfx.Texture,
}

// Slice lookup by name; slice counts are small, linear scan.
texture_sprite_rect :: proc(tex: ^Texture2D, name: string) -> (Sprite_Rect, bool) {
    for s in tex.sprites {
        if s.name == name do return s, true
    }
    return {}, false
}

_texture_sprites_free :: proc(tex: ^Texture2D) {
    for s in tex.sprites do delete(s.name)
    delete(tex.sprites)
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

    path, path_ok := asset_db_get_path(uuid.Identifier(guid))
    if !path_ok do return nil, false

    g := _texture_decode_file(path)
    if g == nil {
        artifact := _artifact_path(uuid.Identifier(guid))
        defer delete(artifact)
        g = _texture_decode_file(artifact)
    }
    if g == nil do return nil, false

    ppu := f32(PIXELS_PER_UNIT)
    sprites: []Sprite_Rect
    if settings, sok := asset_pipeline_get_settings(path, context.temp_allocator); sok {
        if ts, is_tex := settings.(TextureSettings); is_tex {
            if ts.pixels_per_unit > 0 do ppu = ts.pixels_per_unit
            // Settings live on the temp allocator — the cache owns clones.
            if ts.sprite_mode == .Multiple && len(ts.sprites) > 0 {
                sprites = make([]Sprite_Rect, len(ts.sprites))
                for s, i in ts.sprites {
                    sprites[i] = s
                    sprites[i].name = strings.clone(s.name)
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

// Cacheless load for editor UI images (About logo). Caller owns the texture
// (gfx.texture_destroy).
texture_load_file :: proc(path: string) -> (^gfx.Texture, bool) {
    if gfx.device() == nil do return nil, false
    g := _texture_decode_file(path)
    return g, g != nil
}

// stb decodes top-down RGBA8, matching SDL_GPU's top-left uv origin.
_texture_decode_file :: proc(path: string) -> ^gfx.Texture {
    data, read_err := os.read_entire_file(path, context.temp_allocator)
    if read_err != nil do return nil

    w, h, channels: i32
    pixels := stbi.load_from_memory(raw_data(data), i32(len(data)), &w, &h, &channels, 4)
    if pixels == nil do return nil
    defer stbi.image_free(pixels)

    return gfx.texture_create(pixels[:w * h * 4], w, h)
}
