---
title: "Render Pipeline"
description: "The frame as an asset: a .renderpipeline places render nodes in a frame lane and per-slot lanes, cameras name a slot, the window edits it live"
order: 110
tags: ["rendering", "engine"]
path: engine/rendering
---

## What it is

A render pipeline is an asset that describes one frame: which render nodes run, in which order, with which settings. The project renders through one pipeline (Project Settings > Rendering, the essentials plugin's `Default.renderpipeline` when unset). A camera names a slot of it (`Camera.slot`, `Main` by default) and renders through that slot's lane. The editor's scene view renders through the `Editor` slot when the pipeline declares one, `Main` otherwise.

The shape follows Stride's graphics compositor (an asset with entry points cameras reference) with URP's renderer asset as the user-facing model (a list of passes with settings, duplicated and edited per project).

## The asset

`.renderpipeline` is JSON: `slots` (names), `nodes` (placed instances), `next_id`. A placed node is `{id, node, slot, binds, settings}`: `node` names a registered `@(render_node)` proc, `slot` the lane (`""` is the frame lane), `binds` the ports bound to another target name than the node declares, `settings` the values of the node's settings struct (absent keys keep the node's defaults).

Order is list order: within a lane the nodes run in the order they appear in `nodes`. What the window shows is what runs.

A placed node may be muted (`muted`): it stays in the asset and the frame runs as if it were not there, which shows what the node adds.

## The window

Window > Rendering > Render Pipeline shows one slot at a time, picked by the tabs, as a matrix:

- **Columns** are the slot's passes in run order, the frame lane's left of a divider. Each lane ends with a `+` column that adds a pass from the palette (every installed node, grouped by package).
- **Rows** are the resources the passes touch: `scene` (the view's objects), then every target in the order it first appears, with its format and size.
- **Cells** mark what a pass does to a resource: writes it (square), reads it (circle, with a dot when it reads it as `final`), or reads and writes it in place (square in a third color). A red ring is a read with no writer before it. A bar spans each resource's lifetime, from its first pass to its last.
- **Selecting a pass** (its header or a cell) tints the rows it reads, the rows it writes and the rows it changes in place in three colors. **Selecting a row** outlines it, and its tooltip names its writers and readers.
- **Editing:** drag a header onto another to reorder or move a pass between the frame lane and the slot, right-click a header to insert before or after it, mute it, open its code or remove it. The tabs add, rename and remove slots.

The pane on the right holds three sections, each shown or hidden by its toolbar button (Selected Pass, Resource List, Pass List). Its width and the split between the selected pass and the lists drag like the Project view's panes, and both are saved per developer:

- **The pass:** its summary, its inputs as their writers left them and its outputs as it left them, as thumbnails from the running frame, "Show in scene view" per output, its settings, mute, open code, remove, its port bindings, and what it drew (objects, meshes, materials, textures: a click selects the object or pings the asset).
- **Resource List** and **Pass List:** every row and column with its details, searchable. The Filter button hides scratch resources (written by one pass and read by none, such as bloom's blur textures), the `scene` row and muted passes.

Edits render as they are made (`render_pipeline_preview`), Save writes the asset, undo is one step per edit.

## Inspecting a frame

While the window draws, the engine captures the slot it shows (`render_inspect_request`): the scene view's run of that slot, or the first camera's when the scene view renders another slot, and the frame lane whenever it runs. After each node it copies every target the node took into a thumbnail, so an in-place target like `hdr` has one image per pass that drew into it, each as that pass left it. It also records what each node drew. "Show in scene view" copies one pass's target at full size and draws it over the scene view's image at the end of the view's run. A closed window costs nothing.

## Ports

A node's reads and writes are bound by name: a read takes the target of that name from the pool, a write creates it. The declared names are the defaults. A placed node may rebind a port, so two blooms in one lane write `bloom` and `bloom_wide` and the tonemap picks which it reads, or a debug node reads `depth` instead of `hdr`. In the settings pane a read is a combo over the targets written earlier in the lane and in the frame lane, plus `final`, and a write is a name field. The node's code keeps using the declared name (`render_target(ctx, "bloom")`), the pipeline maps it.

A sequence with named ports carries the same information as a wired node graph: a node reading two targets is a join, two nodes reading one target is a fork, and any graph without cycles lists in some order. The lanes are that order, and the ribbons are the wires.

## Lanes

- The **frame lane** holds per-frame nodes (`frame=true`): the shadow map, a probe. Each runs once per frame, whichever slot asks first, with the frame's target pool.
- A **slot lane** holds per-view nodes. A slot runs once per view that names it: every camera with that slot, the scene view for `Editor`. Each run has its own `Render_Ctx` and the view's target pool.

The default pipeline: frame lane `environment_pass`, `shadow_pass`, `Main` lane `scene_opaque`, `scene_sky`, `scene_under`, `scene_transparent`, `scene_over`, `postfx_bloom`, `postfx_tonemap`, `postfx_fxaa`, `final_blit`.

## Nodes

A node is a proc with one attribute:

```odin
@(render_node={summary="blurs what is brighter than the threshold", reads="final", writes="bloom:HDR@0.5", settings="bloom_defaults"})
postfx_bloom :: proc(ctx: ^engine.Render_Ctx) {
	s := (^Bloom_Settings)(ctx.settings)
	src := engine.render_input(ctx, engine.FINAL_INPUT)
	dst := engine.render_target(ctx, "bloom")
	...
}
```

- `summary` is one line of what the node does, shown in the window.
- `writes` declares each target the node renders as `name[:LDR|HDR][@scale|@Npx][*]`. `render_target(ctx, name)` allocates it from the declaration (the view's size times the scale, or fixed pixels, required on a per-frame node). `*` makes it the view's final image when the node takes it, so a node that returns early leaves the earlier final in place.
- `reads` names what the node samples. `render_input(ctx, name)` returns the view's target, a frame node's, or `final`, the finished image so far. nil when no node took that target earlier this frame, even if the pool still holds an older texture of that name. A node that draws the view's objects reads `scene`, which is always there and is not a texture.
- `settings` names a package-level var holding the settings struct's defaults. Each placed instance gets its own copy, edited in the window, stored in the asset, handed to the node as `ctx.settings`.
- `frame=true` makes a per-frame node.

The prebuild checks the declarations (format, sizes, `final` reserved, a frame node cannot read `final` or scale to a view) and that every node name is unique across installed packages, then emits the registrations. Which nodes run is the asset's business, so the prebuild does no ordering.

## Drawing into the scene

The scene nodes are each one gfx pass on the view's `hdr` target sharing its depth (`gfx.pass_begin_target` with `keep_depth`). A node placed between them calls `scene_target_begin(ctx)` to get the same target with the camera set and the shadow map bound, and `render_execute(view, commands, phases)` to draw the view's commands of one phase its own way.

## Validation at load

A pipeline is user data, not an engine invariant, so a problem warns once and the frame still renders:

- a placed node that is not installed (a plugin's node whose link is gone) is skipped
- a node in a slot the pipeline does not declare, or a per-frame node in a slot lane, is skipped
- a read nothing before it in the lane writes (the frame lane counts as before every slot lane) is reported, the node runs and its `render_input` returns nil

A camera naming a slot the pipeline lacks renders through `Main` with one warning.

## Files

- `plugins/engine/render_pipeline.odin`: the asset, the active pipeline, `render_pipeline_run`
- `plugins/engine/render_node_registry.odin`: the node registry, `Render_Ctx`, `render_target`, `render_input`
- `plugins/engine/render_inspect.odin`: the frame capture the window reads
- `plugins/engine/render_nodes.odin`, `render_shadow.odin`: the engine's nodes
- `plugins/engine/gen/render_node_gen.odin`: the prebuild checks and registrations
- `plugins/engine/editor/render_pipeline_view`: the window
- `plugins/essentials/assets/rendering/Default.renderpipeline`: the default
- [SDL3 Renderer](SDL3Renderer.md): the gfx seam below
