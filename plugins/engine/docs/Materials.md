---
title: "Materials"
description: "Material assets for MeshRenderer: a built-in shader with its property block, authoring, guid references and caching"
order: 90
tags: ["materials", "rendering", "assets", "engine", "editor"]
path: engine/rendering
---

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
white, lit — the fallback, not an error. A sprite or other quad without a
material stays unlit, so 2D art is never shaded by accident. A new material
starts as Lit.

**Extract from glTF**: select a `.glb`/`.gltf` in the project view →
right-click → `Extract Textures & Material`. Embedded images are written as
plain files next to the model (`<model>_<image>.png/jpg`) and one `.mat`
per glTF material is created with its slots wired — albedo into `texture`,
metal-rough/normal/ao/emissive into the pbr.glsl rows (built-in Lit with
albedo only when that shader asset is missing). Everything extracted is an
ordinary editable asset (deliberately not Unity's read-only sub-assets),
and existing files are skipped so re-running never overwrites your edits.
Materials come out in submesh order — assign them to
`MeshRenderer.materials` in file order.

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
| `lit` | `.Lit` | physically based (metal/roughness: GGX, height-correlated Smith, Schlick) per light, driven by the scene's **Light** components, plus the ambient level as a uniform environment. Its surface is the material's `lit` block |

### The Lit block

`Material.lit` is the built-in Lit's surface, the metal/roughness model glTF uses, in the terms of the engine's Lit material: `metallic`, `smoothness` (1 minus roughness), a `metallic_roughness_map` in glTF's packing (green roughness, blue metallic), a `normal_map` with its `normal_scale`, an `occlusion_map` (red) with its `occlusion_strength`, an `emission_map` with its `emission_color` (brighter than 1 for HDR emission). Each map multiplies its factor, an unassigned map is white, and an unassigned normal map leaves the vertex normal. A material file without the block gets a dielectric of smoothness 0.5. Unlit and custom shaders ignore it.

Diffuse is not divided by pi, so a light of intensity 1 on white albedo lights it to 1, as the earlier Lambert did, and scenes keep their brightness. Assets/Extract Assets maps a glTF material straight onto the block, its linear factors stored as sRGB colors like everything the inspector authors.

### Alpha clipping

`alpha_clip` and `alpha_cutoff` work with every shader: a pixel whose alpha is below the cutoff is not drawn and casts no shadow. The alpha is the texture's times the color's, or what a surface shader sets in `s.alpha`. For leaves, fences and cutout decals, which would otherwise draw their transparent texels into the depth and hide what is behind. A new material has the cutoff at 0.5 and clipping off. Extract Assets turns on clipping for a glTF material in `MASK` mode, with its `alphaCutoff`.

Depth passes (the shadow map, the depth prepass) draw a clipped material through its shader's caster, the same `surface()` without lighting, so the shadow has the same holes as the surface. A mesh whose materials do not clip draws depth with one shared shader whatever its materials, so its copies merge into one instanced draw (SDL3Renderer.md, Depth passes and alpha clipping).

### Environment

The **Environment** component (Rendering/Environment) is the scene's sky and the light it gives what no Light reaches. The first enabled one in the world drives the scene:

- `sky`: Procedural (a gradient from `ground` through `sky_horizon` to `sky_top`, with the sun: the first enabled directional Light's direction and color, its disc `sun_size` degrees across), Panorama (an equirectangular texture, 2:1, turned by `panorama_rotation`), or Color (`sky_top`)
- `exposure` scales the sky, `ambient_intensity` the diffuse light it gives surfaces, `reflection_intensity` what they reflect of it
- `draw_sky` shows it behind the cameras where nothing is drawn, else their clear color stays

The frame lane's `environment_pass` renders it into cubes, only when a setting, the panorama or the sun changed: the sky (512 px a face, with mips), its reflection prefiltered for roughness along six mips (GGX, importance sampled), and its diffuse irradiance. The template lights with them: irradiance times the diffuse color, the reflection read at the surface's roughness times the split-sum fit for specular, both times occlusion. `scene_sky` draws the sky after the opaque meshes. Without an Environment the first Light's ambient level lights uniformly and nothing is reflected.

A panorama is any color texture for now. HDR images (`.hdr`, float) need a float texture import, not done yet.

### Light component

Directional, Point or Spot via `type` (Unity's `Light.type`): `color`,
`intensity`, plus `range` (point/spot falloff end), `spot_angle` /
`inner_spot_angle` (full cone angles, degrees) and `ambient` (unlit floor). A
directional light travels along the transform's forward (-Z, like cameras);
point and spot sit at the transform's position, spot aiming along forward.

Rendering gathers EVERY enabled light, up to 256 (the pool max), for each pass (`scene_collect_lights` → `gfx.set_lights`), and gfx bins them into screen tiles, so a fragment lights with the lights whose range reaches its tile (SDL3Renderer.md, Lights). The ambient floor comes from the first enabled light in slot order. Scenes without a light
get a neutral default (one white directional, down-ish, 0.35 ambient) so
unlit-era scenes look unchanged. Point/spot falloff is the smooth
`(1 - (d/range)^2)^2` — predictable zero at range, no inverse-square hot
center — and spot fades between the inner and outer cone.

`shadows` makes a light cast shadows: the first enabled directional one through cascades fitted to each view, spot and point lights through tiles of one atlas, up to 48 tiles (a spot light takes 1, a point light 6), in light order (SDL3Renderer.md, Shadows). The pipeline needs the `shadow_cascades` and `shadow_atlas` nodes, which the Default pipeline has.

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

`plugins/engine/material.odin` — guid-keyed cache mirroring textures/meshes, but
GPU-free (works headless, fully testable):

- `material_load(guid)` — cache hit or read+parse the `.mat` file.
- `material_preview(guid, mat)` — editor hook: the inspector pushes the open
  material's values into the cache every frame (live editing).
- Invalidation: `asset_db_refresh` drops cache entries for externally
  changed/deleted `.mat` files (git checkout, other tools).

`render_execute` resolves each material once per pass (shader name, texture, color, property block) and calls `gfx.draw_mesh(..., shader)` per submesh. Draws sort by material, mesh and submesh, so equal ones merge into instanced draws (SDL3Renderer.md, Instancing).

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
  samplers at bindings 1..6 become named texture rows (see below). Binding 7 is the directional cascades' shadow atlas, 8 and 9 the environment's reflection and irradiance cubes, 10 the spot and point lights' shadow atlas, bound by gfx for shaders that declare them (the surface template does). The importer accepts up to binding 10 (`SHADER_MAX_SAMPLERS`, gfx's `MAX_FRAGMENT_SAMPLERS`)
- optional `LightUBO` at `set = 3, binding = 0`: `ambient_count` (x ambient
  floor, y light count), `cam_pos` (xyz camera world position — pair it with
  `frag_world_pos` for specular/fresnel), then `lights[8]`, the first 8 of the pass's lights, of four vec4s each:
  `pos_type` (xyz position, w kind: 0 dir, 1 point, 2 spot), `dir_range` (xyz
  travel direction, w range), `color_outer` (rgb premultiplied by intensity, w
  cos outer half-angle), `params` (x cos inner half-angle). Copy the block from
  `lit.frag.glsl`
- optional **material property block** at `set = 3, binding = 1` — any
  uniform block of floats/vec2/vec3/vec4
- **color space:** the shader works in linear light and writes linear light (the view's last pass encodes to sRGB). `frag_color`, light colors, the ambient level and color properties arrive already linear. A texture holding color (albedo, emissive) is stored as sRGB and must be decoded where it is sampled (`srgb_to_linear` in the surface template, `pow(c, vec3(2.2))` in a full shader). Data textures (normal maps, masks, metal/rough) are not decoded
- **color properties:** a vec4 whose name contains "color" or "colour" (any case) is a color: the inspector shows a picker and the value, authored in sRGB, is packed as linear. A color brighter than 1 is an sRGB color times a linear intensity

### Surface shaders

A `.glsl` asset that declares `void surface(inout Surface s)` and no `main()` is a **surface shader**: the importer compiles it between the two halves of the template, `libs/gfx/shaders/surface.glsl` (the inputs, the light UBO, the `Surface` struct, `view_dir()`) and `surface_main.glsl` (presets the surface, calls `surface()`, runs the lambert light loop). The built-in `lit` shader is the same template with an empty `surface()`, so a surface shader is lit exactly like it. Sample: `assets/shaders/rim.glsl`.

```glsl
layout(set = 3, binding = 1) uniform MaterialUBO { vec4 rim_color; float rim_power; };

void surface(inout Surface s) {
    float rim = pow(1.0 - max(dot(s.normal, view_dir()), 0.0), rim_power);
    s.emissive = rim_color.rgb * rim;
}
```

- `s.albedo` and `s.alpha` arrive as `texture(tex, frag_uv) * frag_color` (the texture decoded to linear), `s.normal` as the interpolated world normal, `s.emissive` as zero. Change what you need
- PBR: `s.metallic` (preset 0), `s.smoothness` (preset 0.5) and `s.occlusion` (preset 1) feed the same lighting as the built-in Lit
- normal maps: `s.normal = perturb_normal(texture(bumps, frag_uv).xyz * 2.0 - 1.0, strength)` turns a tangent-space texel into the world normal, through the vertex tangent (`frag_tangent`, location 4) or a frame from derivatives where the vertex has none. A normal map is data: never `srgb_to_linear` it
- the template declares the inputs, `tex`, the `LightUBO` and the shadow maps, so the shader declares only its property block and extra textures, which work as for any user shader. A surface shader is shadowed by every Light with `shadows` on, like the built-in lit shader
- with the material's alpha clipping on, a pixel whose `s.alpha` ends below the cutoff is discarded. The importer also compiles the shader's caster (the template with `MOONHUG_CASTER`: `surface()` and the clip, no lighting), what shadows and the depth prepass draw a clipped material with, so a graph that cuts holes through `s.alpha` cuts them in its shadow too
- set 3 binding 2 is gfx's per-draw block (`DrawUBO`, the alpha cutoff): a property block stays at binding 1
- the template widens a highlight where the normal turns faster than a pixel can show (`specular_aa`) and caps a light's specular term, so fine bright detail does not flicker between pixels (SDL3Renderer.md, Mip levels and specular aliasing). The built-in Lit also roughens its normal map's smaller mip levels (`toksvig_smoothness`), which a surface shader can call on its own normal map
- compiler errors keep the shader's own line numbers (`#line 1`)
- the template is what a shader graph emits (plugins/shadergraph), so a hand-written surface shader and a graph-made one are the same kind of asset
- the template is an input of every surface shader: the shader importer's version hashes its text, so a template edit reimports them all

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
`mh shaders` — glslc → SPIR-V, spirv-cross → MSL + reflection — and caches
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
swaps the pipelines live. A compile FAILURE is contained: the artifact index
keeps the last good artifact, so the material keeps rendering with the
previous pipelines, and the failed guid is memoized — no per-frame toolchain
retries — until the next source edit earns one fresh attempt.

## The gfx seam

Pipelines are **name-keyed** in gfx: `shader_register(name, ...)` builds the
full pipeline set for a shader pair ("unlit" and "lit" are registered in
`gfx.init`; user shaders register through `shader_register_fragment` under
their guid string, `shader_unregister` enables hot reload). All shaders share
the `Vertex` format, the per-instance `_Instance` format (model matrix and tint) and the vertex UBO layout (`_Uniform`: view_proj) — that contract is what lets `pass_end` switch shaders per draw.

Light gizmos and handles (range sphere, spot cone) live in the editor: docs/core/Handles.md.

A surface shader lights with every light that reaches its fragment's screen tile. A hand-written full shader reads the light uniform's prefix, so it lights with the first 8 lights.
