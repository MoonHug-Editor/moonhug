---
title: "Rendering"
description: "@(render_step) and @(render_collector): a step a render pipeline places, and the procs that hand a view its draw commands"
weight: 50
tags: ["engine", "attributes", "rendering"]
path: engine/attributes
---

Two attributes extend rendering. A render step is one block of a [Render Pipeline](../assets/RenderPipeline.md) asset. A render collector hands a view the draw commands of the renderers it owns.

## @(render_step)

```odin
@(render_step={summary="exposure, bloom added, colour graded, HDR to LDR by the operator",
    reads="final bloom? exposure?", writes="post:LDR*", settings="tonemap_defaults"})
postfx_tonemap :: proc(ctx: ^engine.Render_Ctx) {
    s := (^Tonemap_Settings)(ctx.settings)
    // record the step's passes
}
```

- The proc's name is the step's name, unique across installed packages. It is what a pipeline asset places.
- `summary` is one short line, shown on the step's block in the Render Pipeline window.
- `writes` declares each target the step renders as `name[:FORMAT][@scale|@Npx][*]`. FORMAT is LDR or HDR, the size is a fraction of the view or fixed pixels, and `*` makes it the view's final image.
- `reads` names the targets the step samples. `final` is the finished image so far, `scene` is the view's objects, and a name ending in `?` is optional.
- `settings` names a package var holding the step's default settings. Each placed step has its own copy, edited in the window and saved in the asset.
- `frame=true` makes a step that runs once per frame before every view, such as a shadow map.

## @(render_collector)

```odin
@(render_collector)
collect_sprites :: proc(view: engine.Render_View, out: ^[dynamic]engine.Render_Command) {
    // append a command for each visible sprite
}
```

- The proc appends the draw commands of its renderers that `view` sees. The steps that read `scene` draw them.
- The engine's mesh, skinned mesh and canvas collectors are declared the same way.

## Reference

- [@(render_step)](/docs/reference/attributes/engine/render_step.md), [@(render_collector)](/docs/reference/attributes/engine/render_collector.md)
- [Render pipeline](../RenderPipeline.md): ports, lanes, steps and drawing into the scene.
