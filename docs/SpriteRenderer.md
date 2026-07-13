# SpriteRenderer
---

**How it fits together:**
```
engine/
  texture2d.odin            ← Texture2D struct + GUID→texture cache
  components.odin           ← SpriteRenderer component definition

editor/
  view_scene.odin           ← billboard rendering in scene view
  inspector/
    property_drawer_asset_guid.odin  ← Asset_GUID field drawer
```
---

## 1 — Texture2D and the texture cache

`Texture2D` is a runtime representation of a loaded texture. It wraps a raylib texture handle alongside the asset GUID and dimensions:

```odin
Texture2D :: struct {
    guid:       Asset_GUID,
    width:      i32,
    height:     i32,
    rl_texture: rl.Texture2D,
}
```

A global `texture_cache: map[Asset_GUID]Texture2D` avoids redundant loads. On first request the loader resolves the GUID to a source path via AssetDB, loads the image through raylib, uploads it to the GPU, and stores the result. Subsequent calls return the cached entry:

```odin
texture_load :: proc(guid: Asset_GUID) -> (^Texture2D, bool)
texture_unload :: proc(guid: Asset_GUID)
```

The cache is initialized after the asset pipeline and torn down before the AssetDB during editor shutdown.

---

## 2 — SpriteRenderer component

`SpriteRenderer` is an ECS component attached to a Transform. It references a texture asset by GUID and carries rendering parameters:

```odin
@(component)
SpriteRenderer :: struct {
    using base: CompData,
    texture: Asset_GUID,
    color:   [4]f32,       // tint, defaults to white {1,1,1,1}
    visible: bool,         // defaults to true
}
```

It follows the same `@(component)` pattern as `Sprite` and `Script` — the prebuild generator produces pool entries, type keys, component menus, and serialization hooks automatically.

Added via the menu bar: **Component → SpriteRenderer**, or programmatically:
```odin
transform_add_comp(tH, .SpriteRenderer)
transform_get_or_add_comp(tH, engine.SpriteRenderer)
```

---

## 3 — Scene view rendering

During `render_scene_rt`, after the grid and axis lines, `draw_sprite_renderers` iterates every alive slot in the `sprite_renderers` pool:

```
for each alive SpriteRenderer:
    skip if not visible or texture GUID is nil
    resolve owner Transform → world position + scale
    texture_load(guid) → get or cache the GPU texture
    compute billboard size from texture dimensions × transform scale (pixels / 100 = world units)
    DrawBillboardRec facing the scene camera with the tint color
```

Sprites always face the camera (billboard mode). Size is derived from the texture's pixel dimensions scaled by the transform's scale, normalized at 100 pixels per world unit.

---

## 4 — Inspector: Asset_GUID property drawer

Any serializable struct field of type `Asset_GUID` gets the asset reference drawer automatically. The drawer:

1. Resolves the GUID to a filename via `asset_db_get_path` and displays it as a button (or "None" if empty)
2. Accepts drag-and-drop from the project view (`ASSET_PATH` payload) — dropping an asset sets the GUID
3. Shows an **X** clear button when a value is assigned

---

## 5 — Scene serialization

`SceneFile` carries a `sprite_renderers: [dynamic]SpriteRenderer` array. During save, the collect pass copies each `SpriteRenderer` into the scene file. During load, `scene_file_instantiate` creates pool entries and resolves `local_id` → handle mappings, same as other component types.

---

## 6 — Sorting (sorting_layer / order_in_layer / SpriteSortingGroup)

Unity semantics, resolved in `engine/sprite_sort.odin`:

```
sorting_layer  →  order_in_layer  →  view depth (back-to-front)  →  scene-tree order
```

- `SpriteRenderer.sorting_layer` and `.order_in_layer` are plain i32s (Unity's
  Sorting Layer / Order in Layer). Defaults of 0 reproduce pure depth sorting.
- When every explicit key ties, sprites draw in scene-tree order — so sibling
  subtrees are atomic by default (Godot-style painter ordering as the tiebreak).
- `SpriteSortingGroup` (component) makes its whole transform subtree sort as ONE
  unit against outside sprites, using the group's layer/order and the group
  root's depth; members keep sorting among themselves by their own keys. Groups
  nest (up to 7 levels deep); a disabled group stops grouping.

Implementation: one scene-tree pass per view packs each sprite's resolved key
into `[8]u64` words (`layer:8 | order:16 | ~depth:24 | tree_seq:16` per
hierarchy level) — O(n), no per-sprite ancestor walks, and keys are unique so
draw order is total and deterministic. `render_execute` sorts meshes first,
then sprites by key. Tests: `tests/sprite_sorting_tests.odin`.

---

## Lifecycle

| Phase | What happens |
|---|---|
| EditorInit | `texture_cache_init()` after asset pipeline + DB init |
| Frame loop | `draw_sprite_renderers()` inside `render_scene_rt` |
| EditorShutdown | `texture_cache_shutdown()` before AssetDB shutdown |

---
