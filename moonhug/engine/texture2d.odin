package engine

import rl "vendor:raylib"
import "core:encoding/uuid"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:path/filepath"

Texture2D :: struct {
    guid:       Asset_GUID,
    width:      i32,
    height:     i32,
    rl_texture: rl.Texture2D,
}

texture_cache: map[Asset_GUID]Texture2D

texture_cache_init :: proc() {
    texture_cache = make(map[Asset_GUID]Texture2D)
}

texture_cache_shutdown :: proc() {
    for _, &tex in texture_cache {
        if rl.IsTextureValid(tex.rl_texture) {
            rl.UnloadTexture(tex.rl_texture)
        }
    }
    delete(texture_cache)
}

texture_load :: proc(guid: Asset_GUID) -> (^Texture2D, bool) {
    if tex, ok := &texture_cache[guid]; ok {
        return tex, true
    }

    path, path_ok := asset_db_get_path(uuid.Identifier(guid))
    if !path_ok do return nil, false

    img := rl.LoadImage(strings.clone_to_cstring(path, context.temp_allocator))
    if img.data == nil {
        artifact := _artifact_path(uuid.Identifier(guid))
        defer delete(artifact)
        img = rl.LoadImage(strings.clone_to_cstring(artifact, context.temp_allocator))
    }
    if img.data == nil do return nil, false
    defer rl.UnloadImage(img)

    rl_tex := rl.LoadTextureFromImage(img)
    if !rl.IsTextureValid(rl_tex) do return nil, false

    tex := Texture2D{
        guid       = guid,
        width      = img.width,
        height     = img.height,
        rl_texture = rl_tex,
    }
    texture_cache[guid] = tex
    return &texture_cache[guid], true
}

texture_unload :: proc(guid: Asset_GUID) {
    if tex, ok := &texture_cache[guid]; ok {
        if rl.IsTextureValid(tex.rl_texture) {
            rl.UnloadTexture(tex.rl_texture)
        }
        delete_key(&texture_cache, guid)
    }
}
