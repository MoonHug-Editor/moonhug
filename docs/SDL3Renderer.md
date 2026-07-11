# SDL3 Renderer

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

The renderer is its own package, `moonhug/engine/gfx` (precedent: `engine/log`,
`engine/serialization`). `import sdl "vendor:sdl3"` appears ONLY inside gfx
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
  `engine.render_world_cameras(...)` / `gfx.frame_end()`. Editor reaches
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
Render_Target :: struct { color, depth: ^sdl.GPUTexture, width, height: i32 }
// imgui 1.92.2+ SDLGPU3 convention: ImTextureID is the RAW ^sdl.GPUTexture
// (passing a sampler-binding pointer — the pre-1.92.2 convention — reads
// garbage and crashes in Metal). texture_imgui_id/rt_imgui_id return it;
// re-fetch each frame since rt_resize recreates the color texture.

// window / input
init :: proc(title: cstring, w, h: i32) -> bool     // sdl.Init + window + GPU device + pipelines
shutdown :: proc()
poll_events :: proc(event_cb: proc(e: ^sdl.Event) = nil)  // editor passes imgui ProcessEvent
quit_requested, delta_time, window_size, pixel_size, window_position,
set_window_geometry, display_usable_bounds
input_key_down / input_key_pressed / input_key_released :: proc(k: Key) -> bool
input_mouse_down / input_mouse_pressed / input_mouse_position / input_wheel
input_focus_gained :: proc() -> bool                // edge; drives editor asset refresh

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
rt_create / rt_resize / rt_destroy / rt_imgui_id

// draws (valid inside a pass)
set_view_proj :: proc(vp: matrix[4,4]f32)           // callable mid-pass: camera stacking, screen-space UI
draw_quad :: proc(corners: [4][3]f32, uvs: [4][2]f32, color: [4]f32, tex: ^Texture)  // tex=nil → white
draw_line :: proc(a, b: [3]f32, color: [4]f32, depth_test := true)  // false → overlay pipeline (gizmos)
draw_mesh :: proc(mesh: ^Mesh, tex: ^Texture, model: matrix[4,4]f32, color: [4]f32)
debug_text :: proc(pos_px: [2]f32, size_px: f32, color: [4]f32, text: string)
```

Pipelines (all from ONE shader pair): triangles no-depth-write (sprites,
alpha-blended), triangles depth-write (meshes), lines depth-tested, lines
overlay. Depth `D32_FLOAT`; offscreen targets use the swapchain format so one
pipeline set serves both. Draw-order policy: meshes first (depth-write), then
sprites back-to-front by view depth (no depth-write). Semi-transparent meshes
sorting wrong is accepted for now.

Shaders: GLSL (Vulkan-style) source in `moonhug/engine/gfx/shaders/`, compiled
OFFLINE to SPIR-V by `glslc` and crossed to MSL by `spirv-cross` (both
`brew install shaderc spirv-cross`; DXIL added when Windows lands). This is the
same pipeline SDL_shadercross uses internally — chosen over shadercross itself
because shadercross has no release binaries. **Compiled blobs are committed**
and embedded via `#load`; runtime picks the format via
`sdl.GetGPUShaderFormats` (MSL entry point is `main0`, SPIR-V is `main`).
Contributors never need the toolchain unless they change a shader. SDL_GPU
SPIR-V binding convention: vertex uniform buffers = set 1, fragment sampled
textures = set 2.

## Render commands (engine side)

`engine/render.odin` is rewritten around per-frame command lists (temp
allocator — no persistent buffers; same spirit as the old TODO, simpler):

```odin
Render_View    :: struct { view, proj, inv_vp: matrix[4,4]f32, width, height: f32, layer_mask: u32 }
Draw_Sprite    :: struct { texture: Asset_GUID, model: matrix[4,4]f32, color: [4]f32 }
Draw_Mesh      :: struct { mesh, texture: Asset_GUID, model: matrix[4,4]f32, color: [4]f32 }
Render_Command :: struct { depth: f32, variant: union #no_nil { Draw_Mesh, Draw_Sprite } }

camera_view_proj        :: proc(cam: ^Camera, aspect: f32) -> (view, proj: matrix[4,4]f32)
render_collect_commands :: proc(view: Render_View, out: ^[dynamic]Render_Command)
render_execute          :: proc(view: Render_View, commands: []Render_Command)  // guid→cache→gfx.draw_*
render_world_cameras    :: proc(rt: ^gfx.Render_Target)  // nil = swapchain; ALL enabled cams by order
camera_screen_ray       :: proc(cam: ^Camera, px, py, vw, vh: f32) -> Ray  // replaces rl.GetScreenToWorldRay
```

- Layer culling only (`t.render_layer & view.layer_mask`); no frustum culling.
- Sprites stay transform-oriented quads (NOT billboards), 100 px/unit;
  `sprite_world_corners` helper is shared by draw AND picking so they can't
  diverge.
- The editor scene view builds a `Render_View` from its own plain-data camera
  and goes through the SAME collect/execute — game view and scene view render
  identically by construction.

## Roadmap

### 0. Dependencies + shaders + doc stubs
- [x] `brew install sdl3` (vendor:sdl3 links `system:SDL3`); note in README
- [x] shader toolchain: `brew install shaderc spirv-cross` (shadercross has no
      release binaries; glslc + spirv-cross is the same pipeline)
- [x] `engine/gfx/shaders/world.vert.glsl` + `world.frag.glsl` (SDL_GPU SPIR-V
      convention: vertex UBO set=1, fragment sampler2D set=2)
- [x] `compile.sh` → committed `compiled/*.{spv,msl}` (MSL entrypoint `main0`);
      guarded hook in run.sh

### 1. gfx package: window + input (new code, unused yet)
- [x] `engine/gfx/platform.odin` — init/window/event pump/frame timing; vsync
      via swapchain params (no SetTargetFPS equivalent; dt-based logic copes)
- [x] `engine/gfx/input.odin` — per-frame input snapshot (down/pressed/released,
      mouse, wheel, text, focus_gained edge) mirroring every current rl call site
- [x] Checkpoint: tree compiles with raylib + SDL3 linked side by side; tests green

### 2. gfx package: GPU core
- [x] `engine/gfx/gfx.odin` — device, pipelines, textures, meshes, frame begin/end
- [x] `engine/gfx/pass.odin` — passes, CPU batch → copy pass → render pass,
      render targets, draw procs (seam above)
- [x] `engine/gfx/shaders.odin` — `#load` blobs, format negotiation
- [x] `engine/gfx/debug_text.odin` + `font8x8.odin` — embedded 8×8 bitmap font
      (replaces rl.DrawText in the app demo menu; future debug overlay)
- [x] `matrix4_perspective_z01` / `matrix4_ortho_z01` in `engine/gfx/math.odin`
      (SDL_GPU clip z∈[0,1]; core linalg is GL-style)
- [x] Checkpoint: `engine/gfx/scratch` validation window (since deleted) —
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
- [x] `engine/render.odin` — full rewrite straight to render commands (above);
      killed `camera_to_3d`; `render_world_cameras` leaves its pass OPEN for
      caller overlays (demo menu, editor)
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
- [x] `engine/asset_pipeline.odin` — `.glb`/`.gltf` importable, `MeshSettings{scale}`
      in ImportSettings union, importer "mesh"
- [x] `engine/asset_importer_mesh.odin` — `vendor:cgltf` parse + load_buffers
      (one-time: `make -C "$(odin root)/vendor/cgltf/src"`); bakes node world
      matrices, merges triangle primitives into one blob (flat normal / zero
      uv fallbacks; winding flipped when node determinant < 0); AABB.
      Artifact `library/artifacts/<guid>.bin`:
      `"MHMESH1\0" | vertex_count u32 | index_count u32 | submesh_count u32 |
      aabb_min [3]f32 | aabb_max [3]f32 | vertices(gfx.Vertex) | indices(u32)`
      (submesh_count =1 reserved for the multi-material follow-up). Prefer
      `.glb` (a `.gltf`+`.bin` pair mints a harmless extra guid for the .bin)
- [x] `engine/mesh.odin` — cache mirroring texture2d.odin: `mesh_load(guid)`
      (artifact missing → reimport → retry; headless-safe without a GPU
      device), wired next to texture_cache in app_init and editor init/shutdown
- [x] prebuild rerun (MeshSettings typ_guid)
- [x] Checkpoint: import tests over generated `tests/fixtures/meshes/cube.glb`
      (24 verts / 36 indices / ±0.5 AABB; scale setting honored; garbage blobs
      rejected); the in-editor cube renders in phase 6

### 6. MeshFilter + MeshRenderer + picker ext: filter
- [x] `engine/component_MeshFilter.odin` — `mesh: Asset_GUID` `ext:"glb,gltf"`
- [x] `engine/component_MeshRenderer.odin` — `texture: Asset_GUID`
      `ext:"png,jpg,jpeg,bmp"` (empty = untextured white), `color: [4]f32
      decor:color()` (Unity parity: filter=data, renderer=appearance; no
      material system yet)
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
- [x] `editor/scene_pick.odin` — sprites via `sprite_world_corners` + 2 triangle
      tests; meshes via ray→local space + artifact AABB; nearest t wins; editor
      ignores layer mask (Unity behavior). CPU picking, NOT GPU id-buffer
      (hundreds of objects; id-buffer = extra pipeline + readback for no gain)
- [x] LMB click hook in `handle_scene_input` (pressed+released under a 4px drag
      threshold, no Alt) → `inspector_request_select`; miss clears selection
- [x] Checkpoint: raycast unit tests green (127 tests); in-editor — click
      sprite → hierarchy selects; rotated cube selects; sky click clears;
      nearest of overlapping wins (VERIFY IN EDITOR)

### 8. Selection outline + translate gizmo + scene toolbar
- [ ] Outline in scene pass: mesh → 12 AABB edges through model matrix; sprite →
      quad outline; neither → axis cross. Unity orange `{1, 0.6, 0.1, 1}`
- [ ] `editor/gizmo.odin` — Translate only, world axes, no plane handles first
      cut (Rotate/Scale = disabled toolbar stubs). Constant screen size
      (`distance * 0.15`); overlay lines; hover = mouse-ray↔segment distance;
      drag = closest-point-on-axis parameter delta
- [ ] `transform_set_world_position` in `engine/transform.odin`
      (inverse-parent TRS)
- [ ] Undo: `undo.field_drag_begin/end` around the drag — docs/Undo.md already
      anticipates viewport gizmos; one undo step per drag
- [ ] Scene-window overlay toolbar (icon buttons over the image) + W/E/R keys
      gated on hovered && !flythrough (W collides with fly-WASD)
- [ ] Checkpoint: X-arrow drag moves a rotated child under a rotated parent
      along world X only; one Ctrl+Z reverts the drag; gizmo click never picks

### 9. Purge + docs
- [ ] `grep -rn "vendor:raylib" moonhug/` → zero hits; delete dead code/comments
- [ ] docs: finish this file's design sections as things land; `docs/Meshes.md`
      (artifact format, components, glb guidance, submesh follow-up)
- [ ] README: sdl3 install note; move done TODO items to Features; Rotate/Scale
      gizmos as remaining TODO

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
