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
## Asset catalog and builds

`library/catalog.json` is one dictionary file mapping every asset guid to its
source path, current artifact key and baked import settings — Unity's
Addressables catalog idea, reduced to what the catalog pipeline needs. Assets read
straight from source (scenes, materials, clips) carry an empty artifact key.
Nothing about it is user-facing:

- the editor maintains it AUTOMATICALLY (`asset_catalog_auto`): every import
  pass and refresh rewrites it, a byproduct like artifact_db.json
- the app loads one with `--catalog[=path]` (`asset_db_init_from_catalog`): the
  guid↔path maps, artifact index and import settings come from the file —
  nothing scans `assets/`, no `.meta` is read
- under the catalog pipeline the catalog is authoritative: refresh no-ops and
  runtime imports are refused with an error — a missing artifact surfaces
  instead of being repaired by importing

**Builds run through run configs** (docs/Plugins.md "Run
configurations") — a config is the build config, written as straight-line
code:

```odin
main :: proc() {
    rc.play({package_path = "moonhug/packages/app", out = "builds/app"}, "packages/app/assets/demo_menu/menu.scene")
}
```

- `rc.play` is `rc.build`, `rc.export_data`, `rc.run_build` in a row, and the toolbar modifiers turn the same call into a dev run, a run of the last build, or a build with no run, so one config and one button cover every way of playing. The three steps stay public for a config that needs something between them
- `rc.export_data` stages `<out>_data` beside the binary — Unity's
  `Game` + `Game_Data` layout — from the editor-maintained catalog
  (`catalog.export_from`, moonhug:engine/catalog — a leaf package, so config
  binaries stay small): the boot scene's DEPENDENCY CLOSURE (every asset it
  references, transitively) and a RELOCATABLE catalog whose paths and `artifacts/` fan-out resolve
  relative to its own directory. The data dir moves as one unit and is
  self-contained — the round-trip test boots it with the working tree's
  `assets/` and `library/` deleted
- one representation per asset: an asset with an artifact ships the artifact
  (mesh parts and baked clips included) and not its source, an asset without one (scene,
  material, prefab) ships its source. Every runtime loader reads the artifact
  first and reaches the source only through an import request, which the
  catalog pipeline refuses, so the artifact's existence is the whole rule and
  no importer declares anything. The entry keeps its path as the key for
  settings and type lookups
- what ships: the boot scene, everything under any folder named `resources`
  (for assets the game loads by path at runtime, which the walk cannot see),
  and everything they reference. References are found by harvesting guid
  strings from each asset's bytes and baked settings, so every asset type is
  covered by one rule and the walk can only ship too much, never too little.
  An unreferenced asset outside `resources` does not ship. With no pinned
  scene the whole catalog ships
- the config's `scene` pins the boot scene (stamped into the catalog as a
  guid): every launch of a config produces the same build. An app on the catalog pipeline with
  no scene argument boots the stamped scene
- a binary launched bare, with no `--catalog`, looks for `<exe>_data/catalog.json`
  beside itself first, so a build double-clicked in `builds/` boots its own
  export. Only with no data dir beside it does it fall back to the editor's
  in-place `library/catalog.json`
- `out` names the build, not the package: the samples all compile the app
  runner package but as `builds/particles_sample`, `builds/physics2d_sample`
  and so on, each with its own `_data`, so building one never overwrites another
- toolbar: two **Build & Run** buttons, both driving the selected config.
  The right one (beside the config dropdown) runs it verbatim — its own
  pinned scene. The middle one (beside the Simulate controls) forwards the
  CURRENT scene state to the run — unsaved edits on the built binary, assets
  still resolving through the catalog. On both, **Alt = dev run** (build,
  then run against the editor's live library catalog with no export, the
  fast loop), **Shift = run only** (skip the compile and the staging, run the
  last build) and **Alt+Shift = build only**. The rc helpers own the protocol
  (`rc.scene_arg`, `rc.dev_run`, `rc.run_only`, `rc.build_only`), config
  files never see it

The app has ONE pipeline: catalog. With no flag it boots the editor-maintained
in-place `library/catalog.json` (dev runs, the Play button), with `--catalog`
an export. No catalog = a clear error saying to run the editor once. The
import pipeline exists only inside the editor.

## Read/write split

The pipeline's WRITE half lives in `moonhug:engine_editor/asset_pipeline`
and never links
into a game binary: importer registry + built-in importers (texture, mesh,
shader), the import drivers (`asset_pipeline_import_all/import_asset/
reimport`), the AssetDB scan (`asset_db_refresh` — tree walk, meta minting,
orphan pruning), meta writing, import-settings saving. The progress API is
its own editor subpackage (`moonhug:editor/progress` —
`progress.begin/report/end`).
Package importers follow the same split — the audio importer lives in
`packages/audio/editor/`, its settings type stays in the runtime package so
the catalog pipeline materializes settings in game binaries too (settings
objects carry `__type_guid`, read registry-free via `_settings_from_value`).

The engine keeps the READ half: the AssetDB storage and lookups (guid↔path
maps, root-info index, meta primitives), the artifact index, artifact path
resolution, meta/settings reading, catalog init. Three seams connect the
halves, all installed at the editor's ImportersInit and nil in the app:

- `asset_db_set_refresh_proc` — engine code requests a scan through it:
  `asset_db_init` (storage init, paired with `asset_db_shutdown` in the
  engine) and scene_save both do
- `asset_pipeline_set_import_request` — loader self-heal: a missing or
  stale artifact at load (fresh clone, format bump) reimports in the
  editor and is a plain load error in the app
- a path-changed hook reimports edited `.glsl` (shader hot reload)
- an asset-gone hook (`asset_db_add_asset_gone_hook`) fires after a refresh for every asset that left the project. A rename or move keeps its guid under a new path, so it never fires. The editor drops the asset's open document and its undo steps there.

## UX

Per ImporterSettings struct of each type:
    - when file of supported extension is selected in project view, resolve property drawer to show settings in project inspector view, with apply button at top
    - when pressing apply it should reimport resource

*.asset and *.scene files keep special inspector behavior for now