# Materials

Unity-style Material assets for MeshRenderer: a material picks a **built-in
shader** and supplies its property block (texture + color). Follows the same
asset conventions as everything else — a JSON file under `assets/` with a
`.meta` guid, referenced by guid, cached at runtime.

## Authoring

- **Create**: project view → `Assets/Create/Material` → writes
  `New Material.mat` into the current folder.
- **Edit**: click the `.mat` file — it opens in the Project Inspector
  (shader dropdown, texture picker, color). Edits render **live** in the
  scene/game views; **Save** persists them (unsaved edits revert on the next
  editor run).
- **Assign**: add entries to a MeshRenderer's `materials` list (one per
  submesh — see [Meshes](Meshes.md)) via drag or the picker (filtered to
  `.mat` via the field's `ext:` tag). Submesh i uses `materials[i]`.

A submesh without a material (missing entry or empty guid) renders plain
white unlit — the fallback, not an error.

## Built-in shaders

| Name | Material_Shader | Effect |
|---|---|---|
| `unlit` | `.Unlit` | `texture * color`, no lighting |
| `lit` | `.Lit` | unlit × fixed directional lambert (baked light dir, 0.35 ambient floor) |

The lit shader uses world-space normals via `mat3(model)` — wrong under
non-uniform scale (needs inverse-transpose), accepted for now. Light
components are a follow-up.

## File format

`serialization.write_asset_to_path` shape — `__type_guid` first, then the
marshaled `engine.Material` fields:

```json
{
  "__type_guid": "4d201ba5-2097-48bb-abd3-1a79e4f6f6f4",
  "shader": 0,
  "texture": [ ... 16 guid bytes ... ],
  "color": [1, 1, 1, 1]
}
```

Fields absent from a file keep code defaults (`_material_parse`: white,
unlit) so old assets survive Material growing new properties.

## Runtime

`engine/material.odin` — guid-keyed cache mirroring textures/meshes, but
GPU-free (works headless, fully testable):

- `material_load(guid)` — cache hit or read+parse the `.mat` file.
- `material_preview(guid, mat)` — editor hook: the inspector pushes the open
  material's values into the cache every frame (live editing).
- Invalidation: `asset_db_refresh` drops cache entries for externally
  changed/deleted `.mat` files (git checkout, other tools).

`render_execute` resolves `Draw_Mesh.material` → shader name + texture +
color and calls `gfx.draw_mesh(..., shader)`. Meshes sort by material guid so
same-material draws share pipeline/texture binds.

## The gfx seam (custom shaders later)

Pipelines are **name-keyed** in gfx: `shader_register(name, vert_spv,
vert_msl, frag_spv, frag_msl)` builds the full pipeline set for a shader pair
("unlit" and "lit" are registered in `gfx.init`). All shaders share the
`Vertex` format and the UBO layout (`_Uniform`: view_proj, model, tint) —
that contract is what lets `pass_end` switch shaders per draw.

User-authored shaders are the designed follow-up: a `.glsl` asset importer
running the `shaders/compile.sh` toolchain (glslc + spirv-cross, already
optional brew deps) whose artifact feeds `shader_register`; `Material_Shader`
then widens from an enum to a shader reference. Also deferred: float/vector
property blocks (spirv-cross `--reflect` can supply exact UBO offsets at
import time) and light components for the lit shader. Per-submesh materials
are done (see Meshes.md).
