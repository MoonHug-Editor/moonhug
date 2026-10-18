---
title: "Layers"
description: "Named layers per domain: objects hold layer bits, consumers hold masks, the render layer names live in a Render Layers asset chosen in the Layers project setting, plugins own domains of their own"
order: 95
tags: ["layers", "rendering", "physics", "engine", "editor"]
path: engine/rendering
---

A layer sorts objects for one system. An object holds layer bits, a consumer holds a mask, and the consumer handles an object when the two share a bit. Layers are per domain: the engine's render domain sorts objects for views, and a plugin can own a domain of its own, as the physics plugins do for their colliders. An object's render layer says nothing about what it collides with.

## Domains and names

Each domain has 32 layers, bit N for layer N, and a list of 32 names. An empty name is an unused layer. The engine owns one domain:

- `"render"` (`LAYER_DOMAIN_RENDER`): `Transform.render_layer` and the camera, light and probe masks

The physics plugins own one each, with their own layers asset (names and collision matrix) and settings: `"physics2d"` and `"physics3d"` ([physics2d](../../physics2d/assets/README.md) and [physics3d](../../physics3d/assets/README.md) "Collision layers").

The registry (`moonhug/libs/core/layers.odin`) hands out each domain's names:

- `layer_names(domain)` is the list, nil for a domain no owner registered
- `layer_name(domain, layer)` is one name, empty for an unused layer
- `layer_index(domain, name)` is the layer with that name, -1 when none has it
- `layer_hidden_mask(domain)` is the layers the picker does not list

An owner registers a list once with `layer_domain_register(domain, &names, hidden, refresh)` and rewrites it in place when the names change. Registering a domain again with the same list is allowed, with another list panics. An owner whose names come from an asset passes a `refresh` proc: `layer_names` calls it before every read, so a reader never sees names older than the asset, and the owner needs no per-frame hook.

## The Render Layers asset

The render layer names live in a Render Layers asset (`engine.Render_Layers`), a plain `.asset` file with one list of 32 names, `names`. The Layers project setting (Edit ▸ Project Settings… ▸ Layers, saved to `ProjectSettings/layers.json`) names the asset the project uses in `render_layers`, whose picker lists only Render Layers assets (`ref:"Render_Layers"`). An unset field is the essentials plugin's default asset, `assets/rendering/DefaultRenderLayers.asset`, and the built-in names when the essentials plugin is not installed either. A new asset, the default asset and the built-in names are the same:

- render layer 0, `RENDER_LAYER_DEFAULT`, is "Default". A new object is on it
- render layer 31, `RENDER_LAYER_EDITOR`, is "Editor". It is reserved for the editor: thumbnails and the inspector's live previews draw their content on it and their views draw nothing else, so the open scene never shows in them. The picker does not list it

The inspector draws the asset as 32 fixed rows, one per layer: layers 0 and 31 read "Builtin Layer N" with their names fixed and greyed out, the others read "User Layer N" with a text field (`decor:layer_names(builtin="0,31")`, `moonhug/editor/inspector/layer_names.odin`). Each finished name edit is one undo step.

The engine keeps one copy of the active asset's names and registers it as the render domain (`plugins/engine/layers_asset.odin`). `layers_sync` brings the copy up to date: each frame and every read of the names call it. The copy follows:

- a change of `render_layers` in the Layers setting, from the Project Settings window, an undo or a load
- a change of the asset file on disk
- an edit of the active asset in the inspector, saved or not (`render_layers_preview`). Save writes the file, unsaved edits revert on the next editor run

A field that names a missing asset, or an asset of another type, logs a warning and gives the domain the built-in names.

To give a project its own names:

1. Create an asset with Assets ▸ Create ▸ Render Layers
2. Name its layers in the inspector and save it
3. Pick it in the `render_layers` field of Project Settings ▸ Layers

Picking another asset there switches every render layer picker to the new asset's names. The layer bits in scenes do not change, so an object on layer 3 stays on layer 3 under whatever name the new asset gives it.

## Collision matrix inspector

`decor:collision_matrix(names="names")` on a `[32]u32` field draws it as a triangle of checkboxes, one per pair of named layers, with the layer names over the columns (`moonhug/editor/inspector/collision_matrix.odin`). The names come from the named `[32]string` field of the same struct, so an asset's matrix is labelled with that asset's own names, saved or not. Bit j of row i set means layers i and j collide. A checkbox sets both bits of the pair, so the matrix stays symmetric, and each click is one undo step. The physics plugins' layers assets use it.

## The render domain

Every collector tests `Transform.render_layer & view.layer_mask` and skips the object when no bit is shared: meshes, skinned meshes, the canvas, sprites and particles.

## Objects and consumers

| Holder | Field | Holds | New value |
|---|---|---|---|
| Transform | `render_layer` | the layers the object is on | layer 0 |
| Camera | `render_layer_mask` | the layers the camera draws | every layer |
| Reflection_Probe | `culling_mask` | the layers the capture draws (Materials.md) | every layer |
| Light | `culling_mask` | the layers the light lights | every layer |
| Light | `shadow_caster_mask` | the layers that cast into the light's shadow map | every layer |

An object can be on several layers at once. Children do not inherit their parent's layers: each transform holds its own bits.

## Light masks

A mesh whose layers share no bit with a light's `culling_mask` gets no light from it. Each mesh draw carries its object's layers into gfx (`Draw_Mesh.layers`, `draw_mesh` `layers`, `DrawUBO.draw_layers.x`), each light carries its mask (`params.w` of its `GpuLight`, as bits), and the surface template's light loop skips a light whose mask misses the draw's layers. Draws on different layers never merge into one instanced draw. Quads and other batch draws are on every layer, so every light lights them. A hand-written full shader that reads the light prefix ignores the masks.

A light's shadow map takes only the casters on a layer of its `shadow_caster_mask`. A mesh outside it still receives the light's shadows from other casters.

## Pass flags

Pass flags are not layers: they say which passes draw a renderer, whatever view looks at it. MeshRenderer and SkinnedMeshRenderer hold two:

- `cast_shadows`: On casts with its materials' face culling, Off never casts, Double_Sided casts with no face culling (a one-sided leaf plane still shadows from behind), Shadows_Only casts and draws in no colour, depth prepass, normals or probe pass
- `reflections`: Hidden leaves the renderer out of every reflection probe capture, so a mirror inside a probe's box does not reflect itself

A view's `pass` (`core.View_Pass`: Color, Shadow, Probe) tells the mesh collectors which flags to honour (`render_pass_includes`). Camera and editor views are Color, the shadow casters' view is Shadow, a probe capture's views are Probe. Scene view picking tests the renderers themselves, so a Shadows_Only mesh still picks.

## The picker

A `u32` field tagged `decor:layers(domain="render")`, or with a plugin's domain such as `decor:layers(domain="physics2d")`, draws as a dropdown with "Nothing", "Everything" and a checkbox per named layer of the domain. The closed dropdown reads "Nothing", "Everything", the names of the layers that are on (up to three), or "Mixed". The hidden layers do not count: a mask with every listed layer on reads "Everything". "Nothing" sets the mask to 0 and "Everything" to every bit. Each change in the dropdown is one undo step, across the whole selection. The object inspector draws a Render Layers row with the same picker in its header, under the name, for the whole selection (`inspector.layer_mask_field`).
