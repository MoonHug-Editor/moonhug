---
title: "Render Pipeline"
description: "The frame as an asset: a .renderpipeline places render steps in a frame lane and per-slot lanes, cameras name a slot, the window edits it live"
order: 110
tags: ["rendering", "engine"]
path: engine/rendering
---

## What it is

A render pipeline is an asset that describes one frame: which render steps run, in which order, with which settings. The project renders through one pipeline (Project Settings > Rendering, the essentials plugin's `Default.renderpipeline` when unset). A camera names a slot of it (`Camera.slot`, `Main` by default) and renders through that slot's lane. The editor's scene view renders through the `Editor` slot when the pipeline declares one, `Main` otherwise.

## The asset

`.renderpipeline` is JSON: `slots` (names), `steps` (placed instances), `next_id`. A placed step is `{id, step, slot, binds, settings}`: `step` names a registered `@(render_step)` proc, `slot` the lane (`""` is the frame lane), `binds` the ports bound to another target name than the step declares, `settings` the values of the step's settings struct (absent keys keep the step's defaults).

Order is list order: within a lane the steps run in the order they appear in `steps`. What the window shows is what runs.

A placed step may be muted (`muted`): it stays in the asset and the frame runs as if it were not there, which shows what the step adds.

## The window

Window > Rendering > Render Pipeline shows one slot at a time, picked by the tabs, as a matrix:

- **Columns** are the slot's passes in run order, the frame lane's left of a divider. Each lane ends with a `+` column that adds a pass from the palette (every installed step, grouped by package).
- **Rows** are the resources the passes touch: `scene` (the view's objects), then every target in the order it first appears, with its format and size.
- **Cells** mark what a pass does to a resource: writes it (square), reads it (circle, with a dot when it reads it as `final`), or reads and writes it in place (square in a third color). A red ring is a read with no writer before it. A bar spans each resource's lifetime, from its first pass to its last.
- **Selecting a pass** (its header or a cell) tints the rows it reads, the rows it writes and the rows it changes in place in three colors. **Selecting a row** outlines it, and its tooltip names its writers and readers.
- **Editing:** drag a header onto another to reorder or move a pass between the frame lane and the slot, right-click a header to insert before or after it, mute it, open its code or remove it. The tabs add, rename and remove slots.

The pane on the right holds three sections, each shown or hidden by its toolbar button (Selected Pass, Resource List, Pass List). Its width and the split between the selected pass and the lists drag like the Project view's panes, and both are saved per developer:

- **The pass:** its summary, its inputs as their writers left them and its outputs as it left them, as thumbnails from the running frame, "Show in scene view" per output, its settings, mute, open code, remove, its port bindings, and what it drew (objects, meshes, materials, textures: a click selects the object or pings the asset).
- **Resource List** and **Pass List:** every row and column with its details, searchable. The Filter button hides scratch resources (written by one pass and read by none, such as bloom's blur textures), the `scene` row and muted passes.

Edits render as they are made (`render_pipeline_preview`), Save writes the asset, undo is one step per edit.

## Inspecting a frame

While the window draws, the engine captures the slot it shows (`render_inspect_request`): the scene view's run of that slot, or the first camera's when the scene view renders another slot, and the frame lane whenever it runs. After each step it copies every target the step took into a thumbnail, so an in-place target like `hdr` has one image per pass that drew into it, each as that pass left it. It also records what each step drew. A `Depth` target, and a color target a step drew only the depth of (the depth prepass), show their depth as grey, near white (`gfx.draw_depth_view`). "Show in scene view" copies one pass's target at full size and draws it over the scene view's image at the end of the view's run. A closed window costs nothing. While the window looks at a step before `scene_taa` (the selected one, or the one shown in the scene view), the captured run draws with the steady camera: images drawn before the resolve go through the jittered camera and would move up to half a pixel each frame. Selecting `scene_taa` or a later step brings the jitter back.

## Ports

A step's reads and writes are bound by name: a read takes the target of that name from the pool, a write creates it. The declared names are the defaults. A placed step may rebind a port, so two blooms in one lane write `bloom` and `bloom_wide` and the tonemap picks which it reads, or a debug step reads `depth` instead of `hdr`. In the settings pane a read is a combo over the targets written earlier in the lane and in the frame lane, plus `final`, and a write is a name field. The step's code keeps using the declared name (`render_target(ctx, "bloom")`), the pipeline maps it.

A sequence with named ports carries the same information as a wired node graph: a step reading two targets is a join, two steps reading one target is a fork, and any graph without cycles lists in some order. The lanes are that order, and the ribbons are the wires.

## Lanes

- The **frame lane** holds per-frame steps (`frame=true`): the spot and point lights' shadow atlas, a probe. Each runs once per frame, whichever slot asks first, with the frame's target pool.
- A **slot lane** holds per-view steps. A slot runs once per view that names it: every camera with that slot, the scene view for `Editor`. Each run has its own `Render_Ctx` and the view's target pool.

The default pipeline: frame lane `environment_pass`, `shadow_atlas`, `Main` lane `shadow_cascades`, `scene_ssao` (muted), `scene_opaque`, `scene_sky`, `scene_under`, `scene_transparent`, `motion_vectors`, `scene_taa`, `scene_over`, `postfx_bloom`, `postfx_tonemap`, `final_blit`.

`depth_prepass` is installed but not in the default pipeline. Placed before `scene_opaque`, it draws the opaque meshes' depth first (alpha-clipped ones through their caster) and `scene_opaque` keeps that depth, so each covered pixel is shaded once. It costs a second pass over the geometry, so it pays off with expensive materials and heavy overdraw on a GPU-bound frame. The scene view's debug modes skip it.

## Steps

A step is a proc with one attribute:

```odin
@(render_step={summary="blurs what is brighter than the threshold", reads="final", writes="bloom:HDR@0.5", settings="bloom_defaults"})
postfx_bloom :: proc(ctx: ^engine.Render_Ctx) {
	s := (^Bloom_Settings)(ctx.settings)
	src := engine.render_input(ctx, engine.FINAL_INPUT)
	dst := engine.render_target(ctx, "bloom")
	...
}
```

- `summary` is one line of what the step does, shown in the window.
- `writes` declares each target the step renders as `name[:LDR|HDR|Depth][@scale|@Npx][*]`. A `Depth` target has no color: passes on it are depth-only, each mesh drawn through its shader's depth variant (the shadow atlases are `shadow:Depth@2048px` and `shadow_atlas:Depth@2048px`). `render_target(ctx, name)` allocates it from the declaration (the view's size times the scale, or fixed pixels, required on a per-frame step). `*` makes it the view's final image when the step takes it, so a step that returns early leaves the earlier final in place.
- `reads` names what the step uses from earlier steps. `render_input(ctx, name)` returns the view's target, a frame step's, or `final`, the finished image so far. nil when no step took that target earlier this frame, even if the pool still holds an older texture of that name. A step that draws the view's objects reads `scene`, which is always there and is not a texture.
- a read ending in `?` is optional: the step works without it, as `scene_opaque` works without shadows or ambient occlusion and the tonemap without bloom. A pipeline where nothing before the step writes it loads without a warning, and the window leaves it out. Everything a step takes from another goes through a declared read, so the window shows every dependency and a port binding redirects it: `scene_target_begin` binds the shadows and the ambient occlusion only for a step that reads them (`render_reads(ctx, name)`).
- `settings` names a package-level var holding the settings struct's defaults. Each placed instance gets its own copy, edited in the window, stored in the asset, handed to the step as `ctx.settings`.
- `frame=true` makes a per-frame step.

The prebuild checks the declarations (format, sizes, `final` reserved, a frame step cannot read `final` or scale to a view) and that every step name is unique across installed packages, then emits the registrations. Which steps run is the asset's business, so the prebuild does no ordering.

## Drawing into the scene

The scene steps are each one gfx pass on the view's `hdr` target sharing its depth (`gfx.pass_begin_target` with `keep_depth`). A step placed between them calls `scene_target_begin(ctx)` to get the same target with the camera set and the shadows and ambient occlusion it reads (`shadow?`, `shadow_atlas?`, `ssao?`) bound, and `render_execute(view, commands, phases)` to draw the view's commands of one phase its own way. `render_execute_depth(commands)` draws the meshes into a depth-only pass (`gfx.pass_begin_target` with `color = false`, or a `Depth` target), what the shadow steps and the depth prepass use.

## Temporal anti-aliasing

`scene_taa` smooths edges and thin highlights over several frames. When a lane holds it and the view shades normally, the scene steps draw through a camera offset by a fraction of a pixel, a different offset each frame (8 points of the Halton 2, 3 sequence, `render_draw_view`). `scene_taa` blends each frame into the view's history and writes the result back into `hdr`, so the steps after it see an anti-aliased scene and draw with the steady camera. It goes after the scene steps and before `scene_over`, so the editor's gizmos stay sharp and do not lag.

Each pixel finds where it was last frame:

- through the camera's motion: its position from the depth, taken at the nearest surface in its 3x3 neighbourhood, so an edge moves with what is in front
- through an object's own motion, where `motion_vectors` (placed before `scene_taa`) drew it: the meshes whose model changed since the view's last frame, drawn again into `motion` against the scene's depth, each pixel holding how far it moved on screen. A frame where nothing moved draws nothing there and costs only the check

The history is read there through a Catmull-Rom filter, which keeps its detail while the view moves, and clipped to the spread of this frame's 3x3 neighbourhood (mean and 1.25 standard deviations, in YCoCg), so what was uncovered or changed does not ghost. `blend` (default 0.1) is how much of each frame goes into the result: lower is smoother and steadier. A pixel's own frame counts for more the faster it moves, up to a quarter at 4 pixels per frame, since a moving image shows smearing more than aliasing.

Each view (target pool and camera) keeps its own history, last frame's camera and the models of the meshes it drew. A view that skipped a frame or changed size starts over from its current frame.

Limits:

- a skinned mesh's motion vectors follow its model only, so its animation reprojects through the clipping alone and softens while it moves
- transparent objects have no motion vectors and no depth: they reproject with what is behind them
- the motion pass does not clip, so a moved alpha-clipped mesh writes motion vectors in its holes too

## Ambient occlusion

`scene_ssao`, placed before `scene_opaque`, darkens creases, corners and the ground under objects: how much of the hemisphere above each pixel's surface the view's depth leaves open. A step that reads `ssao?` (`scene_opaque`) takes that as ambient occlusion for its lit draws: it shades the environment's light, together with a material's occlusion map (the smaller of the two counts), and `direct` of the lights' light. The Default pipeline holds it muted: it costs a depth pass over the opaque meshes and three passes over the screen.

- the depth comes from the depth prepass. `scene_ssao` draws it itself when no `depth_prepass` ran before it, and `scene_opaque` keeps it either way
- the surface point and its normal come from the depth. `samples` points spread over the hemisphere around the normal, within `radius` (world units, default 0.5), turned per pixel by a noise pattern
- a sample counts as occluded where the depth at its pixel is in front of it, weighted down the further that surface lies outside the radius, so a near object does not darken a far wall
- two blur passes, across and down, smooth the noise without crossing an object's edge (taps at a different depth count less)
- `intensity` (default 1) scales the occluded fraction. `direct` (default 0.25) is how much of the occlusion also darkens direct light: 0 shades only the environment's light, as the physics says, a little more grounds objects
- the scene view's debug modes skip it
- the result is the `ssao` target: red the factor for the environment's light (the open fraction), blue the factor for the lights' (`direct` of the occlusion), green the view depth

## Validation at load

A pipeline is user data, not an engine invariant, so a problem warns once and the frame still renders:

- a placed step that is not installed (a plugin's step whose link is gone) is skipped
- a step in a slot the pipeline does not declare, or a per-frame step in a slot lane, is skipped
- a read nothing before it in the lane writes (the frame lane counts as before every slot lane) is reported, the step runs and its `render_input` returns nil. An optional read (`name?`) is not reported

A camera naming a slot the pipeline lacks renders through `Main` with one warning.

## Files

- `plugins/engine/render_pipeline.odin`: the asset, the active pipeline, `render_pipeline_run`
- `plugins/engine/render_step_registry.odin`: the step registry, `Render_Ctx`, `render_target`, `render_input`
- `plugins/engine/render_inspect.odin`: the frame capture the window reads
- `plugins/engine/render_steps.odin`, `render_shadow.odin`: the engine's steps
- `plugins/engine/gen/render_step_gen.odin`: the prebuild checks and registrations
- `plugins/engine/editor/render_pipeline_view`: the window
- `plugins/essentials/assets/rendering/Default.renderpipeline`: the default
- [SDL3 Renderer](SDL3Renderer.md): the gfx seam below
