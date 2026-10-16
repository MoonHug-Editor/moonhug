---
title: "SDL3 Renderer"
description: "Migration from raylib to SDL3 and SDL_GPU, mesh components, and the scene-view features built on the new renderer"
order: 110
tags: ["rendering", "meshes", "gizmos", "engine"]
path: engine/rendering
---

Migration from raylib to SDL3 + SDL_GPU, with Mesh components (MeshFilter /
MeshRenderer, glTF import) and the scene-view features that build on the new
renderer: per-camera render commands, click picking, selection outline,
transform gizmos.

## Why

- raylib limits the renderer to rlgl immediate mode and ties window/input to
  its API; imgui already renders through `imgui_impl_opengl3`, so raylib is
  only the platform layer plus sprite quads.
- SDL_GPU is Metal-native on macOS (no deprecated-OpenGL risk), D3D12/Vulkan
  elsewhere, and `external/odin-imgui` already ships prebuilt
  `ImGui_ImplSDL3` + `ImGui_ImplSDLGPU3` backends (v1.92.8-docking, matching
  the bindings) with a working example in
  `external/odin-imgui/examples/sdl3_sdlgpu3/`.
- The renderer surface is small (textured quads, unlit meshes, lines,
  render-to-texture), so the SDL_GPU boilerplate is a one-time cost and the
  shader set is tiny and stable.

Decisions made:
- **SDL_GPU** (not GL — deprecated on macOS, dead tooling; not SDL_Renderer —
  2D only, kills meshes).
- **glTF import from day one** (no primitives-first step).
- **One cutover branch**: raylib fully removed at the end; phases compile in
  order, editor may be degraded mid-branch.

Deliberate behavior changes:
- All enabled cameras render ascending by `Camera.order` (first camera clears
  with its `clear_color`); previously only the single highest-order camera
  rendered.
- `Camera.near_clip` / `far_clip` are honored (raylib hardcoded ~0.01/1000).
- The `scale_ui_for_dpi` workaround toggle is dropped — the SDL3 imgui
  backend owns DPI.

## Package structure

The renderer is its own package, `moonhug/libs/gfx` (precedent: `libs/log`,
`libs/serialization`). `import sdl "vendor:sdl3"` appears ONLY inside gfx
(plus `editor/main.odin` for the imgui backend hookup). The app never touches
SDL directly.

The boundary rule — **gfx never imports engine** — forces the clean split:

- **gfx owns** (a mini-raylib on SDL_GPU, knows nothing about assets/scenes):
  window/events/input snapshot, GPU device + pipelines + shaders, passes,
  render targets, `gfx.Texture` (GPU texture + imgui binding + size),
  `gfx.Mesh` (vertex/index buffers), `draw_quad/draw_mesh/draw_line`,
  `set_view_proj`, embedded bitmap debug font.
- **engine keeps** everything that knows `Asset_GUID`: texture cache
  (`map[Asset_GUID]^gfx.Texture`), mesh cache (guid → `^gfx.Mesh` + AABB),
  cameras, `Render_View`, command collect/execute, raycast.
- **editor/app** drive frames via `gfx.frame_begin()` /
  `engine.render_world_cameras(...)` / `gfx.frame_end()`. A camera renders
  through the render pipeline's slot (render_pipeline.odin, [Render Pipeline](RenderPipeline.md)):
  the scene pass into the view's HDR target, then the tonemap copy onto the
  view's target. Editor reaches
  `gfx.window()` / `gfx.device()` only to init the imgui backends.

Window/input live in the SAME gfx package (not a sibling): the GPU device
claims the window and input rides the same event pump — they always change
together.

## The gfx seam

```odin
package gfx

Vertex :: struct { position: [3]f32, normal: [3]f32, uv: [2]f32, color: [4]u8 }
// ONE vertex format for the CPU batch AND meshes; normals unused by the
// unlit shader, reserved for lighting.

Texture :: struct { gpu: ^sdl.GPUTexture, width, height: i32 }
Mesh    :: struct { vbuf, ibuf: ^sdl.GPUBuffer, index_count: u32 }
Render_Target :: struct { color, depth: ^sdl.GPUTexture, width, height: i32, format: Target_Format }
Target_Format :: enum { LDR, HDR }   // LDR = the swapchain format, HDR = RGBA16F
Target_Pool   :: struct { ... }      // named targets a view owns: pool_target(name, w, h, format), pool_find, pool_destroy
// imgui 1.92.2+ SDLGPU3 convention: ImTextureID is the RAW ^sdl.GPUTexture
// (passing a sampler-binding pointer — the pre-1.92.2 convention — reads
// garbage and crashes in Metal). texture_imgui_id/rt_imgui_id return it;
// re-fetch each frame since rt_resize recreates the color texture.

// window
init :: proc(title: cstring, w, h: i32) -> bool     // sdl.Init + window + GPU device + pipelines
shutdown :: proc()
poll_events :: proc(event_cb: proc(e: ^sdl.Event) = nil)  // editor passes imgui ProcessEvent
quit_requested, delta_time, window_size, pixel_size, window_position,
set_window_geometry, display_usable_bounds

// Input lives in libs/input (import "moonhug:libs/input"): poll_events feeds it,
// call sites read input.key_down / key_pressed / key_released, mouse_down /
// mouse_pressed / mouse_position / wheel, focus_gained (edge; drives editor
// asset refresh), set_mouse_relative, plus the *_fixed tick-latched variants
// (plugins/engine/docs/FixedTick.md).

// frame + passes
frame_begin :: proc() -> bool                       // AcquireGPUCommandBuffer
frame_end   :: proc()                               // Submit
pass_begin_target    :: proc(rt: ^Render_Target, clear: Maybe([4]f32))
pass_begin_swapchain :: proc(clear: Maybe([4]f32)) -> bool   // false when minimized
pass_end             :: proc()   // upload CPU batch (copy pass), then render pass

// resources
texture_create :: proc(pixels: []u8, w, h: i32) -> ^Texture  // own short-lived cmd buffer:
texture_destroy                                              // legal mid-frame (lazy loads)
mesh_create :: proc(vertices: []Vertex, indices: []u32) -> ^Mesh
mesh_destroy
rt_create(w, h, format := .LDR) / rt_resize / rt_destroy / rt_imgui_id
rt_color_texture / rt_depth_texture :: proc(rt) -> Texture   // sample a target an EARLIER pass filled (depth is stored for render targets)

// draws (valid inside a pass)
set_view_proj :: proc(vp: matrix[4,4]f32)           // callable mid-pass: camera stacking, screen-space UI
draw_quad :: proc(corners: [4][3]f32, uvs: [4][2]f32, color: [4]f32, tex: ^Texture)  // tex=nil → white
draw_line :: proc(a, b: [3]f32, color: [4]f32, depth_test := true)  // false → overlay pipeline (gizmos)
draw_mesh :: proc(mesh: ^Mesh, tex: ^Texture, model: matrix[4,4]f32, color: [4]f32, wire := false)  // wire = triangles as lines. A draw matching the previous one joins it as one more instance (Instancing)
draw_fullscreen :: proc(shader: string, inputs: []^Texture, material: []u8 = nil)  // fullscreen_register shaders: blits, post effects. BLIT_SHADER is built in, a .glsl asset registers through engine.shader_load_fullscreen (the postfx plugin)
debug_text :: proc(pos_px: [2]f32, size_px: f32, color: [4]f32, text: string)
```

Pipelines (all from ONE shader pair): triangles no-depth-write (sprites,
alpha-blended), triangles depth-write (meshes), lines depth-tested, lines
overlay. Depth `D32_FLOAT`. A pipeline is bound to its color target's format, so each
shader keeps one pipeline set per Target_Format, built the first time a pass of
that format draws with it (pipelines.odin). Fullscreen shaders pair a
vertex-id triangle with a fragment shader and have their own per-format pipeline. Draw-order policy: meshes first (depth-write), ordered by material, mesh and submesh so equal draws merge into instanced draws, then
sprites back-to-front by view depth (no depth-write). Semi-transparent meshes
sorting wrong is accepted for now.

Shaders: GLSL (Vulkan-style) source in `moonhug/libs/gfx/shaders/`, compiled
OFFLINE to SPIR-V by `glslc` and crossed to MSL by `spirv-cross` (both
`brew install shaderc spirv-cross`; DXIL added when Windows lands). This is the
same pipeline SDL_shadercross uses internally — chosen over shadercross itself
because shadercross has no release binaries. **Compiled blobs are committed**
and embedded via `#load`; runtime picks the format via
`sdl.GetGPUShaderFormats` (MSL entry point is `main0`, SPIR-V is `main`).
Contributors never need the toolchain unless they change a shader. SDL_GPU
SPIR-V binding convention: vertex uniform buffers = set 1, fragment sampled
textures = set 2.

## Color space

Everything gfx draws is lit, blended and filtered in linear light:

- Colors handed to gfx (vertex colors, tints, material colors, clear colors, light colors, the ambient level) are sRGB as authored and decoded once on the way in: the world vertex shader decodes vertex colors and tints, `pass_begin_*` and `set_lights` decode on the CPU. A color brighter than 1 is an sRGB color times a linear intensity.
- Color textures stay stored as sRGB bytes (imgui shows them as they are) and the shaders that sample them decode them: the unlit shader, the lit template's albedo, the shader graph's texture nodes.
- Render targets come in three formats (`Target_Format`). `HDR` is linear float. `LDR` is linear at 8 bits, stored as sRGB so the GPU encodes on write and decodes on sampling. `Display` holds sRGB bytes: the window and every target imgui shows (scene and game views, previews, thumbnails).
- A pass on a Display target draws into a linear scratch target of its size and `pass_end` encodes it, so previews and thumbnails light in linear like the scene. `display_blit` encodes a finished linear image onto a Display target directly: the last pass of a render pipeline (`final_blit`).

## Cubemaps and the environment

`gfx.Cubemap` is an RGBA16F cube: `cubemap_render` draws one face at one mip with a fullscreen shader in its own pass (face order +X, -X, +Y, -Y, +Z, -Z, `shaders/env_common.glsl` face_dir), `cubemap_generate_mips` fills the mips. `set_environment(specular, irradiance, diffuse, specular)` hands a pass its image-based light: sampler slots 8 and 9 (`ENV_SPECULAR_SLOT`, `ENV_IRRADIANCE_SLOT`), bound like the shadow maps at slots 7 and 10 to shaders that declare them, with 1x1 white cubes and the ambient level as intensity when a pass sets none. `draw_sky` is a fullscreen draw on the far plane, depth-tested without writing, so it fills only uncovered pixels.

## Instancing

Every world pipeline reads two vertex buffers. Slot 0 holds the mesh's or the batch's vertices. Slot 1 holds one `_Instance` per drawn object: its model matrix as four columns and its tint (`world.vert` locations 5 to 9). The vertex UBO holds only `view_proj`, pushed once per view.

`draw_mesh` appends the object's instance and joins the previous draw when everything else matches: the mesh and index range, the texture, the shader, the material bytes, the extra textures, the alpha cutoff, the cull mode and mirroring, the view and the pipeline kind. A run of such draws costs one draw call. Entry 0 of a pass's instances is the identity, which batch draws (quads, lines) read, since their vertices are world-space with colors baked in.

The engine orders opaque draws by material, mesh, submesh, cull mode and mirroring (`render_execute`) and depth draws by clipping material, mesh, cull mode and mirroring (`render_execute_depth`), so equal draws arrive in a row. Each material is resolved once per pass. The sort keys are integers sorted without a comparator: at the editor's default optimization a struct comparator cost as much as the draw calls it saved.

## Depth passes and alpha clipping

`Target_Format.Depth` is a target with depth and no color. A pass on one, or `pass_begin_target(rt, clear, color = false)` on a color target's depth, is depth-only: it binds no color attachment and every draw goes through its shader's depth variant. A shader's depth variant is its caster when it has one, else `depth.frag`, which writes depth and nothing else. `DEPTH_SHADER` is a registered shader whose depth variant is `depth.frag`, so meshes drawn with it merge by mesh whatever their materials.

A caster is a fragment stage for depth passes: the surface template compiled with `MOONHUG_CASTER`, which runs `surface()` and discards clipped pixels without lighting. `caster.frag` is the built-in Lit and Unlit shaders' caster. A user surface shader brings its own, compiled by the importer (`shader_register_fragment`'s caster arguments). A shader without one draws depth-only without clipping.

`draw_mesh`'s `alpha_cutoff` is the material's alpha clipping threshold. gfx pushes it in the per-draw block (`DRAW_UNIFORM_SLOT`, fragment set 3 binding 2, `DrawUBO.draw_params.x`), and the surface template, `world.frag` and the casters discard a fragment whose alpha is below it. 0 clips nothing, and batch draws push 0.

`world.vert` declares `invariant gl_Position`, so a depth prepass and the shading pass after it compute the same depth. spirv-cross emits it from MSL 2.1, so `mh shaders` crosses vertex shaders with `--msl-version 20100`. SDL compiles MSL source with the OS's newest language version.

`draw_depth_view(depth, perspective)` draws a depth texture as grey over the target, near white, for the Render Pipeline window. It fetches texels rather than filtering them, since not every GPU filters depth.

## Face culling

`draw_mesh`'s `cull` (`Cull.None`, `.Back`, `.Front`) skips a face of each triangle. Front faces wind counter-clockwise on screen. `mirrored` is for a model whose transform turns the winding around (a negative determinant): its pipeline takes clockwise triangles as front faces, so culling and the shader's `gl_FrontFacing` still see the outside as the front. Wire and overlay draws ignore both and show every face. Each shader builds a mesh pipeline per cull mode and winding the first time a pass of a format draws one, and the shader's pipeline set keeps the unculled, unmirrored ones.

The engine passes the material's cull mode (`material_cull`, from `Material.render_face`, back faces culled by default) and `render_mirrored(model)` to every mesh draw, the depth passes included, so a shadow has the faces the surface has. A mesh draws depth whole only when its materials all cull alike and none clips.

The surface template lights a back face with its normal reversed (`vertex_normal()`, and `perturb_normal` reverses its result), the other side of a thin sheet, as glTF's `doubleSided` asks. `world.vert` multiplies the tangent's bitangent sign by the sign of the model's determinant, so a normal map on a mirrored object tilts the right way.

## Temporal anti-aliasing

`TAA_SHADER` is the resolve, a fullscreen shader: this frame's image, the history, the depth and the motion vectors in (`Taa_Params`: the camera's reprojection, the blend, whether the history and the motion vectors are valid), the blended image out. `MOTION_SHADER` is a world shader that writes a mesh's motion vectors from its `Motion_Params` block (the object's world space now to last frame's, this and last frame's steady cameras), alpha 1 where it drew. `pass_begin_target(rt, clear, shared_depth = scene)` draws into `rt`'s color against another target's depth, kept as it is, so a moved mesh writes motion vectors only where it is in front. The engine's `scene_taa` and `motion_vectors` steps drive them (RenderPipeline.md, Temporal anti-aliasing).

## Fog

`set_fog(Fog)` gives a pass's world draws and sky a fog: `color` (linear), `mode` (Off, Exponential, Exponential_Squared, Linear), `density`, `start` and `end`, `height` and `height_falloff`, and `sky`, the horizon's share. It rides the per-draw block (`DrawUBO`: the alpha cutoff, the fog, the view's camera for the distance), pushed when the cutoff or the view changes, so every world shader reads it the same way (`fog_amount(world_pos)` in surface.glsl and world.frag) and the sky through `Sky_Params` (`draw_uniform_fog`). The height fog is the exponential density integrated along the view ray between the camera's height and the fragment's.

`draw_mesh`'s `blend` draws a mesh alpha-blended, depth-tested but not written (`.Tris`), for transparent materials: the engine orders such draws back to front. Culled and mirrored blended draws get their own pipelines, as the opaque ones do.

## Ambient occlusion

`set_ambient_occlusion(tex)` hands a pass's lit draws the screen's ambient occlusion: the view's size, red how much of the environment's light reaches each pixel, blue how much of the lights'. Shaders that declare `OCCLUSION_SLOT` (the surface template's `ambient_occlusion`, binding 11) get it there, white when none is set. The template reads both at the fragment's screen position (`screen_occlusion()`), shades the environment's light by the smaller of red and the surface's occlusion, and the lights' light by blue. `SSAO_SHADER` and `SSAO_BLUR_SHADER` are the fullscreen passes that make it from a depth texture (`Ssao_Params`, `Ssao_Blur_Params`). The engine's `scene_ssao` step drives them (RenderPipeline.md, Ambient occlusion).

## Screen-space reflections

`set_screen_reflections(tex)` hands a pass's lit draws the screen's reflections: the view's size, premultiplied, rgb what each pixel's mirror ray sees times the confidence, alpha the confidence, with mip levels. Shaders that declare `REFLECTIONS_SLOT` (the surface template's `screen_reflections`, binding 13) get it there, clear when none is set. The template reads it at the fragment's screen position blurrier the rougher the surface and fades it out toward rough surfaces (`screen_reflection(roughness)`), then puts it in place of the environment's reflection by its alpha. `SSR_SHADER` is the fullscreen pass that makes it from the depth, the surfaces' world-space normals and last frame's opaque image (`Ssr_Params`: the projection, the view, the reprojection into last frame's clip space, the march's distance, thickness, steps and edge fade). The engine's `scene_ssr` step drives it (RenderPipeline.md, Screen-space reflections). `NORMALS_SHADER` writes the normals it needs raw when the draw's colour alpha is 0, encoded as colour otherwise, and clips by the draw's alpha cutoff either way.

## Mip levels and specular aliasing

A texture asset gets its full chain of mip levels (`gfx.texture_create(..., mipmaps = true)`): each level half the size of the one above, filled by the GPU from the uploaded pixels (`GenerateMipmapsForGPUTexture`, so the texture is a color target too). A texture seen small samples the level that matches its size on screen instead of one arbitrary texel of the full image, which is what made fine detail shimmer and normal-mapped highlights sparkle. The importer's `mipmaps` setting turns it off (`None`) for a sliced sprite atlas, whose slices would bleed into each other in the smaller levels. Its zero value is `Generate`, so older metas get mip levels. The averaging runs on the stored bytes, so a color texture's levels average sRGB-encoded values, slightly darker than averaging light. `texture_upload_region` regenerates the levels of a mipmapped texture. Textures gfx makes for itself (font atlases, icons, thumbnails, the HDR panorama) keep one level.

The mesh sampler filters trilinearly between levels and anisotropically (8x), so a surface at a grazing angle samples along its stretched footprint.

Highlights that are too small for a pixel flicker between pixels as the camera moves. The surface template counters it twice:

- `specular_aa` (geometric specular anti-aliasing, as Filament and HDRP do) raises the roughness where the shading normal turns faster across the screen than a pixel shows, from its screen derivatives, before the alpha-clip discard.
- `toksvig_smoothness` lowers the built-in Lit's smoothness where its normal map's mip levels averaged diverging normals into a shorter one, so the highlight widens as the bumps blur away. The first hundredth of shortening is 8-bit rounding and ignored.

A light's specular term is capped at 100 times a white diffuse surface, and the template's output at 4096, inside half-float range: a pixel that overflowed was infinite, and bloom blurred it into a white block.

## Lights

`set_lights` takes up to `MAX_LIGHTS` (256) lights per pass, the Light component's pool max, so every enabled light in a world reaches it. gfx splits the target into a fixed grid of `CLUSTER_COLS` x `CLUSTER_ROWS` (16 x 9) tiles and, per view, sets each light's bit in the tiles it reaches: a point or spot light's range sphere, culled against the view's frustum, over the screen rectangle of its bounding box (the whole screen once the box reaches behind the camera), a directional light in every tile. The light list and the tiles' bits (256 per tile) travel in one uniform block at `LIGHT_LIST_SLOT` (3), `ClusterUBO` in the surface template, binned when a view's draws begin and pushed only for passes that light (not depth passes).

The template's light loop finds its fragment's tile from `gl_FragCoord` (`cluster_params` holds the target's size) and walks that tile's bits, so a fragment pays for the lights near it only. A light whose falloff is zero at the fragment is skipped before its shadow lookup. Binning is exact: a render with every bit set matches the binned one pixel for pixel (moonhug-render-perf has the scene, `--lights 200 --dark`).

The light uniform keeps its documented prefix: `ambient_count`, `cam_pos`, then `lights[8]`, the first `LIGHT_UBO_LIGHTS` lights again. A hand-written full shader that declares only that prefix lights with up to 8 lights, all of them per fragment.

The block is about 21 KB. Metal and desktop Vulkan drivers accept it, while the Vulkan specification guarantees only 16 KB for a uniform block, which a Vulkan port has to revisit.

## Shadows

Every Light with `shadows` on casts them, through two render steps (`plugins/engine/render_shadow.odin`):

- `shadow_cascades` (per view) renders the first shadowing directional light's cascades into the view's `shadow` atlas: up to `MAX_CASCADES` (4) slices of the camera's frustum, split between even and logarithmic (`split`), out to `distance`. Each slice is an orthographic view of the sphere around it, so its size holds still as the camera turns, with its centre snapped to whole texels, so shadow edges do not shimmer as the camera moves. The view reaches back toward the light as far as any caster does. One cascade fills the atlas, more share a 2x2 grid.
- `shadow_atlas` (per frame) renders every shadowing spot light's view (one tile) and every shadowing point light's six cube faces (+X, -X, +Y, -Y, +Z, -Z) into the frame's `shadow_atlas`. The tiles form a square grid of as many cells as needed, so more lights make every tile smaller. The tiles travel in the light uniform, so at most `MAX_SHADOW_TILES` (48) fit: lights past the budget in light order render without shadows, with one warning.

Casters are every mesh in the world, collected once per frame and culled per tile against the tile's view. Each atlas is drawn in one depth-only pass with `render_execute_depth`, each tile through `set_view_proj(vp, eye, viewport)`: the viewport (pixels, origin top-left, zero = the whole target) confines the draws after it to that tile.

`gfx.set_shadow_cascades` and `gfx.set_shadow_atlas` hand a pass its maps (scene_target_begin, from shadow_bind). They reach the shader through the light uniform (`cascade_*`, `tile_*`, a light's `params.y`/`params.z` for its first tile and tile count) and two samplers: `shadow_map` at `SHADOW_SAMPLER_SLOT` (7) and `shadow_atlas` at `SHADOW_ATLAS_SLOT` (10). Both sample through a depth comparison sampler with linear filtering, so each of a lookup's 3x3 taps is a 2x2 percentage-closer filter, clamped inside its tile. A 1x1 depth of 1 stands in for a missing map.

The surface template's `cascade_shadow` takes the first cascade whose tile holds the point and fades over the last tenth of the distance. `punctual_shadow` picks a point light's face by the direction's major axis. Both move the lookup along the geometric normal by a few texels (`normal_bias`) and add a bias toward the light in world units (`bias`), which the cascades turn into their own depth units and the perspective tiles apply to the view depth before converting it back.

## Frame statistics

`gfx.stats_last` and `gfx.stats_average` report recent frames: draw calls, instances, triangles, render passes, CPU milliseconds without the GPU waits, and milliseconds waiting for the GPU. The waits are the command buffer and swapchain acquires, which with one frame in flight wait for the GPU to finish the previous frame. The editor's MCP bridge reads them with the `render_stats` tool. Editor UI draws are not counted.

The linear, repeat and nearest samplers set `max_lod` high, so `textureLod` reaches every mip: SDL's zero default clamps each lookup to mip 0. Loops in these shaders count with integers: a float counter (`phi += step`) made Metal return about a third of the irradiance integral.

## Render commands (engine side)

`plugins/engine/render.odin` is rewritten around per-frame command lists (temp
allocator — no persistent buffers; same spirit as the old TODO, simpler):

```odin
Render_View    :: struct { view, proj, inv_vp: matrix[4,4]f32, width, height: f32, layer_mask: u32 }
Draw_Sprite    :: struct { texture: Asset_GUID, model: matrix[4,4]f32, color: [4]f32 }
Draw_Mesh      :: struct { mesh, texture: Asset_GUID, model: matrix[4,4]f32, color: [4]f32 }
Render_Command :: struct { depth: f32, variant: union #no_nil { Draw_Mesh, Draw_Sprite } }

camera_view_proj        :: proc(cam: ^Camera, aspect: f32) -> (view, proj: matrix[4,4]f32)
render_collect_commands :: proc(view: Render_View, out: ^[dynamic]Render_Command)
render_execute          :: proc(view: Render_View, commands: []Render_Command, phases := RENDER_ALL_PHASES)  // guid→cache→gfx.draw_*, the opaque meshes and/or the transparent quads
render_world_cameras    :: proc(rt: ^gfx.Render_Target, overlay: proc())  // nil = swapchain; ALL enabled cams by order, each a run of its pipeline slot; overlay draws over the last camera's scene
render_scene_view       :: proc(rt, view, slot, clear, under, over: proc())  // one editor view through the pipeline slot (the scene view asks for Editor, gets Main otherwise), the grid under and the gizmos over the scene. view.mode (core.View_Mode) picks shaded / wireframe / unlit / normals / overdraw
render_pipeline_run     :: proc(slot: string, ctx: ^Render_Ctx) -> bool  // render_pipeline.odin: the frame lane once per frame, then the slot's lane in canvas order
shadow_cascades / shadow_atlas / shadow_bind                              // render_shadow.odin: the directional cascades per view, the spot and point atlas per frame, handed to gfx.set_shadow_cascades / set_shadow_atlas by scene_target_begin
camera_screen_ray       :: proc(cam: ^Camera, px, py, vw, vh: f32) -> Ray  // replaces rl.GetScreenToWorldRay
```

- Culling: layers (`t.render_layer & view.layer_mask`), and the view frustum when `Render_View.cull` is on. Camera views and the editor scene view turn it on. Probe views leave it off: the shadow steps collecting every caster, thumbnails and previews. The mesh collector tests the mesh's local box moved by the model matrix (`core.aabb_transform`) against the view's six planes (`core.frustum_intersects_aabb`, planes from `core.frustum_from_view_proj` in `render_view_make`). The skinned collector tests the posed bounds after posing, since another view in the same frame may still draw the mesh. The package collectors (sprites, particles, the canvas) do not cull.
- Sprites stay transform-oriented quads (NOT billboards), 100 px/unit;
  `sprite_world_corners` helper is shared by draw AND picking so they can't
  diverge.
- The editor scene view builds a `Render_View` from its own plain-data camera
  and goes through the SAME collect/execute — game view and scene view render
  identically by construction.
- Collection is a registry (`render_register_collector`): a collector is
  `proc(view: Render_View, out: ^[dynamic]Render_Command)`, registered once at
  an init phase. `render_collect_commands` runs the engine's built-in mesh
  collector, then every registered one. Collection order does not
  matter — `render_execute` sorts the combined list. The registry is the seam
  that lets renderer components live in packages: a package owns its component
  pool and emits commands from the engine's vocabulary (`Draw_Quad`,
  `Draw_Mesh`, plus a lexicographic `Sort_Key` for alpha-blended ordering).
  Every command names its `owner`, the transform whose renderer emits it. The
  editor picks, box-selects, outlines and frames package renderers by the
  quads they draw (`editor.drawn_quads`), so a renderer package adds no editor
  code for them.
- Sprites are the first package consumer: `packages/sprites` owns
  SpriteRenderer, SpriteSortingGroup, the sort-key pass (sprite_sort.odin) and
  the collector, registered at ImportersInit. `sprite_quad` (corners + uvs +
  pivot, one resolve) feeds the collector, and the editor's picking,
  selection outlines, framing and thumbnails read the commands it emits.
- `packages/particles` is the second collector: ParticleSystem simulates on
  the CPU (@(update)) and emits billboarded Draw_Quad commands keyed with
  `engine.sort_key_word`, so particles interleave with sprites by
  layer/order/depth.
- `packages/mhgui` is the third collector: Canvas trees resolve RectTransform
  rects in canvas pixels and emit `Draw_Quad` commands whose corners are the
  rect's pixels unprojected onto a plane just inside the near plane, keyed at
  layer 127 so the HUD draws over everything (plugins/mhgui/docs/Gui.md).
- Sprite slicing is importer data, Unity's TextureImporter model:
  `TextureSettings.sprite_mode` + `sprites: [dynamic]Sprite_Rect` (name, pixel
  rect, pivot) live in the texture's meta and bake into the catalog with the
  rest of the settings. `Texture2D` caches the slices. `SpriteRenderer.sprite`
  is a `PPtr{guid, local_id}` — Unity's guid+fileID sub-asset reference: guid
  names the texture, local_id the slice's persistent id (0 = whole texture).
  Ids are minted by the slicer and survive renames and reslicing (the meta's
  slice list is Unity's internalIDToNameTable — the name is a view detail).
  The package's editor half draws the sprite picker (a flat list of every
  pickable sprite) through the inspector funnel and owns the Sprite
  Editor window (`@(editor_window)`): zoom/pan canvas, Slice popup
  (Automatic by transparency islands, Grid By Cell Count, Grid By Cell Size),
  drag-create/move rects, per-slice name/rect/pivot panel, its own
  Apply/Revert against the texture's meta. Opened from the importer
  inspector's Sprite Editor button or Window/Sprite Editor.

## Roadmap

### 0. Dependencies + shaders + doc stubs
- [x] `brew install sdl3` (vendor:sdl3 links `system:SDL3`); note in README
- [x] shader toolchain: `brew install shaderc spirv-cross` (shadercross has no
      release binaries; glslc + spirv-cross is the same pipeline)
- [x] `libs/gfx/shaders/world.vert.glsl` + `world.frag.glsl` (SDL_GPU SPIR-V
      convention: vertex UBO set=1, fragment sampler2D set=2)
- [x] `mh shaders` → committed `compiled/*.{spv,msl}` (MSL entrypoint
      `main0`); builds run it when the toolchain is present

### 1. gfx package: window + input (new code, unused yet)
- [x] `libs/gfx/platform.odin` — init/window/event pump/frame timing; vsync
      via swapchain params (no SetTargetFPS equivalent; dt-based logic copes)
- [x] `libs/gfx/input.odin` — per-frame input snapshot (down/pressed/released,
      mouse, wheel, text, focus_gained edge) mirroring every current rl call site
- [x] Checkpoint: tree compiles with raylib + SDL3 linked side by side; tests green

### 2. gfx package: GPU core
- [x] `libs/gfx/gfx.odin` — device, pipelines, textures, meshes, frame begin/end
- [x] `libs/gfx/pass.odin` — passes, CPU batch → copy pass → render pass,
      render targets, draw procs (seam above)
- [x] `libs/gfx/shaders.odin` — `#load` blobs, format negotiation
- [x] `libs/gfx/debug_text.odin` + `font8x8.odin` — embedded 8×8 bitmap font
      (replaces rl.DrawText in the app demo menu; future debug overlay)
- [x] `matrix4_perspective_z01` / `matrix4_ortho_z01` in `libs/gfx/math.odin`
      (SDL_GPU clip z∈[0,1]; core linalg is GL-style)
- [x] Checkpoint: `libs/gfx/scratch` validation window (since deleted) —
      quads, alpha blend, both line pipelines, mid-pass view_proj switch,
      debug text, offscreen target pass; verified on-screen

### 3. THE CUTOVER (engine → app → editor, one compiling checkpoint)
- [x] `engine/texture2d.odin` — cache holds `^gfx.Texture` values,
      decode via `vendor:stb/image` (force RGBA8); `texture_load(guid)`
      signature unchanged; add `texture_load_file` (About logo)
- [x] editor's imgui swapchain pass is DEPTH-LESS (`pass_begin_swapchain(...,
      depth=false)`) — the imgui pipeline declares no depth attachment; the
      mismatch is an API violation (MTL_DEBUG_LAYER asserts on it; Vulkan is
      stricter still) though Metal happens to tolerate it unvalidated — NOT
      the cause of the cutover segfaults (that was ImTextureID, see Risks)
- [x] `plugins/engine/render.odin` — full rewrite straight to render commands (above);
      killed `camera_to_3d`; caller overlays (demo menu, editor gizmos) draw
      inside the scene pass through the `overlay` proc
- [x] `app/app.odin` — SDL loop; `game.odin`/`tick_player.odin` →
      `gfx.input_*`, `rand.int_max`; `demo_menu.odin` → `gfx.debug_text`
      (screen-ortho `set_view_proj` in the same swapchain pass)
- [x] `editor/main.odin` — `im_sdl.InitForSDLGPU` + `im_sdlgpu.Init`;
      `PrepareDrawData` BEFORE the swapchain pass, `RenderDrawData` inside it;
      focus-regain refresh via `gfx.input_focus_gained()`;
      DELETED `editor/imgui_raylib_input.odin` + all manual imgui IO code +
      the `scale_ui_for_dpi` workaround toggle
- [x] `editor/view_scene.odin` / `view_game.odin` — `^gfx.Render_Target` +
      `rt_resize`; scene camera stays plain orbit data (orbit/fly logic
      unchanged); grid/axes via `gfx.draw_line`; imgui image uvs `{0,0}/{1,1}`
- [x] `editor/view_about.odin`, `editor/window.odin` (SDL display APIs),
      `dock_icon_darwin.odin` unchanged
- [x] Checkpoint: zero `vendor:raylib` imports; tests green; app runs (init +
      loop + shutdown clean); editor starts and runs its loop clean.
      VISUAL parity (tank scene in views, turret aim) verified in phase 4

### 4. Parity polish
- [x] Sprite orientation/uv verification — confirmed in-editor; sprites also
      render SHARPER than raylib did (views run at native HiDPI resolution)
- [ ] Overlapping-sprite alpha/depth check
- [ ] Window position persistence across monitors; ProMotion dt sanity
- [ ] macOS live-resize freeze documented (SDL_AddEventWatch fix deferred)

### 5. glTF mesh pipeline
- [x] `libs/assets/asset_pipeline.odin` — `.glb`/`.gltf` importable, `MeshSettings{scale}`
      in ImportSettings union, importer "mesh"
- [x] `plugins/engine/asset_importer_mesh.odin` — `vendor:cgltf` parse + load_buffers
      (one-time: `make -C "$(odin root)/vendor/cgltf/src"`); bakes node world
      matrices, merges triangle primitives into one blob (flat normal / zero
      uv fallbacks; winding flipped when node determinant < 0); AABB.
      Artifact `library/artifacts/<xx>/<key>.bin` (content-addressed, see README):
      `"MHMESH1\0" | vertex_count u32 | index_count u32 | submesh_count u32 |
      aabb_min [3]f32 | aabb_max [3]f32 | vertices(gfx.Vertex) | indices(u32)`
      (submesh_count =1 reserved for the multi-material follow-up). Prefer
      `.glb` (a `.gltf`+`.bin` pair mints a harmless extra guid for the .bin)
- [x] `plugins/engine/mesh.odin` — cache mirroring texture2d.odin: `mesh_load(guid)`
      (artifact missing → reimport → retry; headless-safe without a GPU
      device), wired next to texture_cache in app_init and editor init/shutdown
- [x] prebuild rerun (MeshSettings typ_guid)
- [x] Checkpoint: import tests over generated `tests/fixtures/meshes/cube.glb`
      (24 verts / 36 indices / ±0.5 AABB; scale setting honored; garbage blobs
      rejected); the in-editor cube renders in phase 6

### 6. MeshFilter + MeshRenderer + picker ext: filter
- [x] `engine/component_MeshFilter.odin` — `mesh: Asset_GUID` `ext:"glb,gltf"`
- [x] `engine/component_MeshRenderer.odin` — `material: Asset_GUID`
      `ext:"mat"` (empty = white, lit; originally raw texture+color, replaced
      by the Material asset — see plugins/engine/docs/Materials.md)
- [x] `Draw_Mesh` emission in `render_collect_commands` (sibling MeshFilter via
      transform_get_comp; skip empty guid); render_execute draws meshes first
      (depth-write), then sprites back-to-front
- [x] Object Picker `ext:` tag: `current_field_ext_filter` in
      `editor/inspector/view_inspector.odin`, row + drag-drop filtering in
      `property_drawer_asset_guid.odin`; SpriteRenderer.texture tagged too
- [x] prebuild rerun
- [x] Checkpoint: save/load round-trip test green (125 tests);
      `assets/meshes/cube.glb` added for the in-editor check — Add Component
      shows both, mesh picker lists only glb/gltf, cube renders in Scene AND
      Game views (VERIFY IN EDITOR)

### 7. Scene picking
- [x] `engine/raycast.odin` — `ray_hit_aabb` (slab, unnormalized-direction
      safe for local-space picking), `ray_hit_triangle` (Möller–Trumbore,
      double-sided); engine-side because game code shares `camera_screen_ray`
- [x] `plugins/engine/editor/scene_tools/scene_pick.odin` — package renderers' drawn quads (the owner on
      each render command) + 2 triangle tests; meshes via ray→local space +
      artifact AABB; nearest t wins; editor
      ignores layer mask (Unity behavior); packages add shapes through
      `handles.pick_register` (docs/core/Handles.md). CPU picking, NOT GPU id-buffer
      (hundreds of objects; id-buffer = extra pipeline + readback for no gain)
- [x] LMB click hook in `handle_scene_input` (pressed+released under a 4px drag
      threshold, no Alt) → `inspector_request_select`; miss clears selection.
      Cmd (Ctrl) + right-click opens the pick menu: every object under the
      pointer (`scene_view_pick_all`), nearest first, a row selects it.
      A right-click that does not look or fly opens the context menu on
      release: the picked object's hierarchy-row menu (selecting it unless it
      is already selected), or the create and view items on empty space
- [x] Checkpoint: raycast unit tests green (127 tests); in-editor — click
      sprite → hierarchy selects; rotated cube selects; sky click clears;
      nearest of overlapping wins (VERIFY IN EDITOR)

### 8. Selection outline + translate gizmo + scene overlay
- [x] Outline in scene pass (`draw_selection_outline`): mesh → 12 local-AABB
      edges through the model matrix; sprite → its exact world quad; neither →
      axis cross. Unity orange `{1, 0.6, 0.1, 1}`, depth-tested lines
- [x] `plugins/engine/editor/scene_tools/gizmo.odin` — all three modes. Translate: world-axis arrows,
      drag = closest-point-on-axis delta. Rotate: world-axis circles, drag =
      signed ray↔plane angle around the axis (grab/current vectors drawn as a
      pie hint), via `transform_set_world_rotation` (inverse-parent). Scale:
      LOCAL-axis handles with octahedron tips + center handle for uniform
      scale (drag right/up grows), factors clamped > 0. Constant screen size
      (`distance * 0.15`); overlay lines; hover = screen-space point↔segment
      distance (8px); W/E/R switch modes (guarded against flythrough WASD)
- [x] `transform_set_world_position` in `plugins/engine/transform.odin`
      (inverse-parent TRS — world drags stay world-correct under rotated /
      scaled parents)
- [x] Undo: `undo.edit_begin/edit_end` around the drag — one undo step per drag
- [x] Scene-window overlay (Move/Rotate/Scale buttons, active
      highlighted) + W shortcut gated on !flythrough (E/R follow with their
      gizmos)
- [x] Checkpoint: builds, 127 tests green, editor runs clean. IN-EDITOR:
      X-arrow drag moves a rotated child along world X only; one Ctrl+Z
      reverts the whole drag; grabbing the gizmo never picks through

### 9. Purge + docs
- [x] `grep -rn "vendor:raylib\|rlgl" moonhug/` → zero hits
- [x] docs: design sections updated per phase; `plugins/engine/docs/Meshes.md` written
      (artifact format, components, glb guidance, submesh follow-up)
- [x] README: install notes (sdl3, stb, cgltf, optional shader toolchain);
      SDL3 Renderer + Meshes moved to Features; remaining TODO = Rotate/Scale
      gizmos (done), Material asset (done — plugins/engine/docs/Materials.md), submesh split

## Verification (every phase)

- `odin build editor -ignore-unknown-attributes` and `odin build app ...` from
  `moonhug/`; `odin test moonhug/tests -ignore-unknown-attributes
  -define:ODIN_TEST_THREADS=1` from the repo root (the 121 tests are headless
  and must stay green throughout).
- Phase 3 onward: run the editor, Play the tank demo (console log pipe, asset
  refresh on focus, sprite orientation).
- Phases 5–8: cube.glb end-to-end — import → pick → render → click-select →
  gizmo drag → undo → save/reload.

## Risks

1. **ImTextureID convention** — RESOLVED the hard way: imgui 1.92.2 changed
   the sdlgpu3 backend's ImTextureID from `^GPUTextureSamplerBinding` to the
   raw `^sdl.GPUTexture`. Passing the old-style binding pointer produced
   random use-after-free crashes (moving crash sites: atomic refcount,
   sampler bind, objc_msgSend). The backend source comments the breaking
   change at the exact crash line — when a GPU crash makes no sense, read
   the backend .cpp first.
2. **Copy-pass/render-pass ordering** in one command buffer (batch uploads,
   imgui PrepareDrawData) → validated by the phase-2 scratch triangle.
3. **Shader toolchain flakiness** → blobs committed, hand-MSL fallback.
4. **Orientation/uv/clip-z flips** (GL vs SDL_GPU conventions) — imgui image
   uvs, sprite uvs, projection helpers; the tank sprite is the canary.
5. **glTF winding under negative scale** — flip indices when the baked node
   matrix determinant < 0 (matters once backface culling is enabled).

## References

- `external/odin-imgui/examples/sdl3_sdlgpu3/` — working SDL3+SDL_GPU+imgui
  example with OUR bindings and prebuilt lib; the editor cutover's template
- [foureyez/odin-sdl3-examples](https://github.com/foureyez/odin-sdl3-examples) —
  Odin ports of [SDL_gpu_examples](https://github.com/TheSpydog/SDL_gpu_examples)
  (triangle → textures → depth → render-to-texture)
- [nadako/hello-sdlgpu3-odin](https://github.com/nadako/hello-sdlgpu3-odin) +
  [YouTube series](https://www.youtube.com/playlist?list=PLI3kBEQ3yd-CbQfRchF70BPLF9G1HEzhy)
  (listed on the [SDL wiki](https://wiki.libsdl.org/SDL3/Tutorials))
- [Moonside Games: SDL GPU sprite batcher](https://moonside.games/posts/sdl-gpu-sprite-batcher/)
  — by an SDL_GPU co-author; our batch is a simpler variant (no instancing/SSBO)
