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

**SpriteRenderer** takes one material too (Unity model): the material's
shader, color (multiplied with the sprite color) and custom-shader
properties apply, but its texture slot is REPLACED by the sprite's own
texture. Empty = unlit, exactly the pre-material sprite look. Set the
material's shader to Lit and sprites shade under the scene's directional
Light using their quad facing (sprites are transform-oriented, so a rotated
sprite lights like a rotated surface). Sprites keep back-to-front alpha
ordering regardless of material; consecutive same-material sprites still
merge into one draw.

## Built-in shaders

| Name | Material_Shader | Effect |
|---|---|---|
| `unlit` | `.Unlit` | `texture * color`, no lighting |
| `lit` | `.Lit` | unlit × directional lambert, driven by the scene's **Light** component |

### Light component

A directional sun: `color`, `intensity`, `ambient` (unlit floor); direction
is the transform's forward (-Z, like cameras) — rotate to aim. Rendering
uses the FIRST enabled light (`_apply_scene_light` → `gfx.set_light`, a
per-pass fragment UBO); scenes without one get a neutral default (white,
down-ish direction, 0.35 ambient) so unlit-era scenes look unchanged.

The lit shader uses world-space normals via `mat3(model)` — wrong under
non-uniform scale (needs inverse-transpose), accepted for now.

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

## Custom user shaders

A `.glsl` asset under `assets/` is a **fragment shader** — the vertex stage
is always the built-in world vertex shader, since the vertex format and UBO
layout are fixed engine contracts. Samples: `assets/shaders/normals.glsl`
(minimal, no properties), `assets/shaders/stripes.glsl` (the property block
walkthrough), `assets/shaders/specular.glsl` (view-dependent shading —
blinn-phong highlight) and `assets/shaders/pbr.glsl` (the full stack:
metallic-roughness PBR with multi-texture rows — assign a glTF model's maps,
Damaged Helmet works out of the box). Conventions:

- inputs: `frag_uv` (loc 0), `frag_color` (loc 1), `frag_normal` (loc 2),
  `frag_world_pos` (loc 3, world-space fragment position) — declare only the
  ones you read
- `sampler2D` at `set = 2, binding = 0` — declare it even if unused; MORE
  samplers at bindings 1..7 become named texture rows (see below)
- optional `LightUBO` at `set = 3, binding = 0`: three vec4s —
  `light_dir_ambient` (xyz direction light travels, w ambient floor),
  `light_color` (rgb premultiplied by intensity), `cam_pos` (xyz camera
  world position — pair it with `frag_world_pos` for specular/fresnel)
- optional **material property block** at `set = 3, binding = 1` — any
  uniform block of floats/vec2/vec3/vec4

### Property blocks

Declare a block and its members become material properties:

```glsl
layout(set = 3, binding = 1) uniform MaterialUBO {
    float normal_mix;
    vec4  tint2;
};
```

Import reflects the std140 layout (member names, offsets, block size) into
the artifact. The Material inspector auto-populates a `properties` row per
member for the assigned shader, with widgets sized to the member type —
one drag for `float`, two/three for `vec2`/`vec3`, a color picker for
`vec4`s whose name contains "color" (drags otherwise); rows whose member
left the shader show dimmed with a remove button
(property_drawer_material_props.odin). Values are matched BY NAME at draw
time, packed into the block layout, and pushed as fragment UBO slot 1 per
draw. Properties the material doesn't set are zero. Matrices/ints/arrays
are not supported as properties.

### Multiple textures

Declare extra samplers past binding 0 and they become texture rows on the
Material, matched by sampler name (same reconcile as properties — rows
appear/disappear with the shader):

```glsl
layout(set = 2, binding = 0) uniform sampler2D tex;        // Material.texture
layout(set = 2, binding = 1) uniform sampler2D detail_tex; // Material row "detail_tex"
```

Binding 0 is always the material's main `texture` field (and for sprites,
the sprite's own texture). Unassigned rows bind WHITE — write shaders so a
white secondary map is a sensible neutral (multiply-style maps like AO/mask
are; a normal map is not — gate normal mapping behind a property, see
`assets/shaders/pbr.glsl`). Up to 8 samplers total.

MSL note: user shaders compile with `--msl-decoration-binding` so GLSL
binding numbers survive as Metal buffer indices — spirv-cross's default
sequential assignment would put a lone binding=1 MaterialUBO at buffer(0),
silently aliasing the light UBO slot.

**Write shaders so all-zero properties still show something** (in-shader
fallbacks, like stripes.glsl's black-stripes default) — freshly synced rows
start at zero, and an effect that's invisible until tuned reads as broken.

Walkthrough (stripes.glsl): create a Material → set `custom_shader` to
stripes.glsl → black stripes appear immediately → `properties` fills with
`stripe_color` / `stripe_count` / `tilt` rows → drag values, the mesh
updates live; Save persists.

Import (`asset_importer_shader.odin`) shells out to the same toolchain as
compile.sh — glslc → SPIR-V, spirv-cross → MSL + reflection — and caches
both blobs plus the reflected resource counts and property layout in the
artifact (`"MHSHDR2\0" | spv_len | msl_len | num_samplers | num_ubos |
block_size | property_count | spv | msl | property table`).
Compile errors land in the editor console with the tool's stderr.
**Authoring shaders needs `brew install shaderc spirv-cross`; opening a
project that contains them does not** (artifacts are cached in library/,
rebuilt only when the source changes).

Assign one via Material's `custom_shader` field (picker filters `.glsl`);
it overrides the built-in `shader` enum when set, and falls back to it when
the shader can't load (missing toolchain, compile error). Editing the
`.glsl` **hot-reloads**: the AssetDB refresh (editor focus) reimports and
swaps the pipelines live.

## The gfx seam

Pipelines are **name-keyed** in gfx: `shader_register(name, ...)` builds the
full pipeline set for a shader pair ("unlit" and "lit" are registered in
`gfx.init`; user shaders register through `shader_register_fragment` under
their guid string, `shader_unregister` enables hot reload). All shaders share
the `Vertex` format and the vertex UBO layout (`_Uniform`: view_proj, model,
tint) — that contract is what lets `pass_end` switch shaders per draw.

Still deferred: multiple/point lights (one directional light per pass now),
imported mesh tangents (pbr.glsl derives a per-pixel cotangent frame
instead), engine-level IBL (pbr.glsl samples an equirect environment via its
`env_tex` row — `assets/textures/studio_env.png` ships as a starter; no
prefiltered mips, roughness blur is approximated), a real linear-color
pipeline (pbr.glsl decodes/encodes sRGB in-shader). Per-submesh materials,
property blocks and multi-texture rows are done (see above and Meshes.md).
