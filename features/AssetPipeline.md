# Asset Pipeline
---

**What lives on disk alongside it:**
```
assets/
  textures/
    wood_planks.png          ← source, authored file
    wood_planks.png.meta     ← sidecar, committed to git

library/
  artifacts/
    3f/
      3fa8c2...bin           ← compiled output, gitignored
```
---

## 1 — Filesystem watcher → Importer dispatch
The watcher monitors assets/ for new or changed files.(Refresh Assets button)

On a change(press Refresh Assets button), it looks up the file extension in an importer registry and calls the matching handler:
```odin
Importer :: struct {
    extensions : []string,
    import_fn  : proc(src_path: string, meta: AssetMeta) -> ([]byte, bool),
}
importer_registry : map[string]Importer  // ".png" -> TextureImporter
```

## 2 — .meta files and the UUID
Every source file gets a .meta sidecar generated on first import. The UUID never changes — it's how the rest of the engine references the asset:

```odin
AssetMeta :: struct {
    // Identity — never changes after creation
    guid             : uuid.Identifier,

    // Dirty detection
    source_mtime     : i64, // maybe no need for hash
    source_hash      : u64,   // optimization when mtime is wrong
    importer_id      : string, // "TextureImporter"
    importer_version : u16,   // bump this to force reimport on all assets

   // Per-type settings (union or tagged union)
    settings         : ImportSettings,

    // Dependency graph
    deps             : []u128, // UUIDs this asset references
}

dirty_check :: proc(record: AssetRecord) -> bool {
    mtime := os.file_modified_time(record.source_path)

    // Fast path: mtime unchanged → definitely clean
    if mtime == record.last_mtime do return false

    // Slow path: mtime changed → confirm with hash
    hash := xxhash64_file(record.source_path)
    if hash == record.source_hash do return false  // false alarm

return true  // genuinely dirty
}
```

## 3 — Asset registry
The registry is the in-memory map from UUID to everything the engine needs to find or load the asset. It's rebuilt from .meta files on startup:

```odin
AssetCategory :: enum {
    Artifact,       // needs importer + artifact (png, wav, gltf)
    Asset,          // serialized directly, no compile step (ScriptableObject equiv.)
    Hybrid,         // has source + compiled output (shader)
}

AssetRecord {
    guid        = 0x1234...,
    category    = .Asset,

    source_path = "assets/data/goblin.enemy",
    cache_path  = "",   // empty — source IS the artifact

    meta,
}

```
## 4 — Compiled artifact cache
The importer writes its output to cache/artifacts/<uuid>.bin — the raw source file is never used at runtime. A texture importer would transcode PNG → your engine's internal format (RGBA8, DXT5, BC7, etc.):

```odin
TextureImporter :: proc(src: string, meta: AssetMeta) -> ([]byte, bool) {
    pixels, w, h := load_png(src)               // decode PNG
    compressed   := compress_bc7(pixels, w, h)  // platform format
    cache_write(meta.uuid, compressed)           // write to cache/
    return compressed, true
}

ImportSettings :: union {
    TextureSettings,
    AudioSettings,
}

TextureSettings :: struct {
    format    : TextureFormat, // RGBA8, BC7, ASTC_6x6, …
    mip_maps  : bool,
    filter    : FilterMode,    // Linear, Nearest, Trilinear
    wrap      : WrapMode,      // Repeat, Clamp, Mirror
    max_size  : u16,           // 0 = no limit
    srgb      : bool,
}

```

## 5 — Runtime loader
At runtime, nothing refers to paths. Entities hold a u128 UUID. The loader checks an in-memory hot cache first, then falls back to reading the compiled artifact:

```odin
asset_load :: proc(uuid: u128, $T: typeid) -> (^T, bool) {
    if hot, ok := hot_cache[uuid]; ok do return cast(^T)hot, true
    record := asset_registry[uuid] or_return
    data   := os.read_entire_file(record.cache_path) or_return
    asset  := deserialize(data, T)
    hot_cache[uuid] = asset
    return asset, true
}
```
## UX

Per ImporterSettings struct of each type:
    - when file of supported extension is selected in project view, resolve property drawer to show settings in project inspector view, with apply button at top
    - when pressing apply it should reimport resource

*.asset and *.scene files keep special inspector behavior for now