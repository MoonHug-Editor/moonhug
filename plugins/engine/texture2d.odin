package engine

import gfx "moonhug:libs/gfx"
import "base:runtime"
import "core:encoding/uuid"
import "core:fmt"
import "core:os"
import "core:strings"

// GUID-keyed texture cache. The GPU side lives in ^gfx.Texture, which is
// heap-allocated by gfx (its embedded imgui binding address must stay stable).
Texture2D :: struct {
    guid:   Asset_GUID,
    // The source image's size, in which sprite rects and pixels per unit are
    // given. The GPU texture is smaller when the import scaled it down
    // (TextureSettings.max_size): gfx.width and gfx.height are its own.
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
}

// Cached textures bake pixels_per_unit at load — a changed or reimported
// texture leaves the cache so new settings apply without a restart.
@(asset_on_changed)
asset_on_changed_texture :: proc(guid: Asset_GUID, path: string, change: Asset_Change) {
    texture_unload(guid)
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
    // A job is loading it (asset_jobs.odin): wait for that job.
    if asset_job_wait(PPtr{guid = guid}, _texture_job_finish) {
        tex, ok := &texture_cache[guid]
        return tex, ok
    }
    // Headless contexts (tests, scene tooling) have no GPU device.
    if gfx.device() == nil do return nil, false
    // A noise map is a texture made from its numbers (noise_map.odin): a
    // .noise file, or a sub-asset of that type in a scene file.
    if asset_type(guid) == "noise" do return _texture_load_noise(guid)

    // The artifact, never the source: the artifact is what an export ships
    // (catalog.export_from copies no source for an imported asset).
    // artifact_file imports a missing one in the editor and reports it once
    // in a game.
    artifact, artifact_ok := artifact_file(guid)
    if !artifact_ok do return nil, false
    data, read_err := os.read_entire_file(artifact, context.temp_allocator)
    if read_err != nil {
        artifact_fail(guid, 0, fmt.tprintf("%s is unreadable (%v)", artifact, read_err))
        return nil, false
    }
    d: _Texture_Decoded
    _texture_decode(data, &d)
    defer gfx.image_free(&d.image)
    return _texture_store(guid, artifact, &d)
}

// Starts loading the texture on a worker thread (asset_jobs.odin): the file
// read and the image decode run there, the GPU upload on the main thread
// when the job finishes. A loaded texture, a noise map and a headless run
// need no job.
texture_load_start :: proc(guid: Asset_GUID) {
    if guid in texture_cache || gfx.device() == nil do return
    if asset_type(guid) == "noise" {
        texture_load(guid)
        return
    }
    artifact, ok := artifact_file(guid)
    if !ok do return
    asset_job_start(PPtr{guid = guid}, artifact, _texture_job_finish, _texture_job_work)
}

// An artifact's image, decoded. Made on any thread.
@(private = "file")
_Texture_Decoded :: struct {
    image:       gfx.Decoded_Image,
    ok:          bool,
    source_size: [2]i32, // the source's size, when the artifact is scaled down
    scaled:      bool,
}

@(private = "file")
_texture_decode :: proc(data: []u8, d: ^_Texture_Decoded) {
    // A scaled-down artifact names its source's size: the texture's size,
    // in which its sprite rects and pixels per unit are given.
    image: []u8
    image, d.source_size, d.scaled = texture_artifact_split(data)
    d.image, d.ok = gfx.image_decode(image)
}

@(private = "file")
_texture_job_work :: proc(job: ^Asset_Job) {
    d := new(_Texture_Decoded, runtime.default_allocator())
    _texture_decode(job.data, d)
    job.user = d
    job.failed = !d.ok
}

@(private = "file")
_texture_job_finish :: proc(job: ^Asset_Job) {
    d := cast(^_Texture_Decoded)job.user
    defer if d != nil {
        gfx.image_free(&d.image)
        free(d, runtime.default_allocator())
    }
    guid := job.ref.guid
    if job.discard do return
    if job.read_failed {
        artifact_fail(guid, 0, fmt.tprintf("%s is unreadable", job.path))
        return
    }
    // Loaded another way while the job ran.
    if guid in texture_cache || d == nil do return
    _texture_store(guid, job.path, d)
}

// The GPU texture of a decoded artifact, in the cache with what the import
// settings say about it. Main thread.
@(private = "file")
_texture_store :: proc(guid: Asset_GUID, artifact: string, d: ^_Texture_Decoded) -> (^Texture2D, bool) {
    // The source path is the key for the settings.
    path, path_ok := asset_db_get_path(uuid.Identifier(guid))
    if !path_ok do return nil, false
    ts: TextureSettings
    has_settings := false
    if settings, sok := asset_pipeline_get_settings(path, context.temp_allocator); sok {
        ts, has_settings = settings.(TextureSettings)
    }
    // A texture without settings gets the default: generated mip levels.
    mipmaps := !has_settings || ts.mipmaps == .Generate
    g: ^gfx.Texture
    if d.ok do g = gfx.texture_from_image(d.image, mipmaps)
    if g == nil {
        artifact_fail(guid, 0, fmt.tprintf("%s does not decode as a texture", artifact))
        return nil, false
    }
    size := d.scaled ? d.source_size : [2]i32{g.width, g.height}
    // Draws sample it as its settings say. Without settings gfx's default
    // holds: meshes repeat, quads clamp.
    if has_settings {
        g.filter = ts.filter == .Nearest ? .Nearest : .Linear
        switch ts.wrap {
        case .Repeat: g.wrap = .Repeat
        case .Clamp:  g.wrap = .Clamp
        case .Mirror: g.wrap = .Mirror
        }
    }

    ppu := f32(PIXELS_PER_UNIT)
    sprites: []Sprite_Rect
    border: [4]f32
    if has_settings {
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

    texture_cache[guid] = Texture2D{
        guid   = guid,
        width  = size.x,
        height = size.y,
        pixels_per_unit = ppu,
        sprites = sprites,
        border = border,
        gfx    = g,
    }
    return &texture_cache[guid], true
}

@(private = "file")
_texture_load_noise :: proc(key: Asset_GUID) -> (^Texture2D, bool) {
    data, _, src_ok := asset_source(key, context.temp_allocator)
    if !src_ok do return nil, false
    n, parsed := noise_map_parse(data)
    if !parsed do return nil, false
    pixels := noise_map_pixels(n, context.temp_allocator)
    g := gfx.texture_create(pixels, n.size, n.size, true)
    if g == nil do return nil, false
    g.wrap = .Repeat
    texture_cache[key] = Texture2D{
        guid   = key,
        width  = n.size,
        height = n.size,
        pixels_per_unit = PIXELS_PER_UNIT,
        gfx    = g,
    }
    return &texture_cache[key], true
}

texture_unload :: proc(guid: Asset_GUID) {
    if tex, ok := &texture_cache[guid]; ok {
        _texture_sprites_free(tex)
        gfx.texture_destroy(tex.gfx)
        delete_key(&texture_cache, guid)
    }
}

