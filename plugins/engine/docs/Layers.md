---
title: "Layers"
description: "Named layers per domain: objects hold layer bits, consumers hold masks, the 32 render and 32 physics names live in a Render Layers and a Physics Layers asset chosen in the Layers project setting"
order: 95
tags: ["layers", "rendering", "physics", "engine", "editor"]
path: engine/rendering
---

A layer sorts objects for one system. An object holds layer bits, a consumer holds a mask, and the consumer handles an object when the two share a bit. Layers are per domain: the render domain sorts objects for views and the physics domain sorts colliders for collisions, so an object's render layer says nothing about what it collides with.

## Domains and names

Each domain has 32 layers, bit N for layer N, and a list of 32 names. An empty name is an unused layer. The engine has two domains:

- `"render"` (`LAYER_DOMAIN_RENDER`): `Transform.render_layer` and the camera, light and probe masks
- `"physics"` (`LAYER_DOMAIN_PHYSICS`): the `layers` and `mask` of the 2D and the 3D colliders, one list for both ([physics2d](../../physics2d/assets/README.md) and [physics3d](../../physics3d/assets/README.md) "Collision layers")

The registry (`moonhug/libs/core/layers.odin`) hands out each domain's names:

- `layer_names(domain)` is the list, nil for a domain no owner registered
- `layer_name(domain, layer)` is one name, empty for an unused layer
- `layer_index(domain, name)` is the layer with that name, -1 when none has it
- `layer_hidden_mask(domain)` is the layers the picker does not list

An owner registers a list once with `layer_domain_register(domain, &names, hidden)` and rewrites it in place when the names change. Registering a domain again with the same list is allowed, with another list panics.

## The layer names assets

The names of each domain live in an asset of its own, a plain `.asset` file with one list of 32 names, `names`:

- a Render Layers asset (`engine.Render_Layers`) names the render layers
- a Physics Layers asset (`engine.Physics_Layers`) names the collision layers

The Layers project setting (Edit ▸ Project Settings… ▸ Layers, saved to `ProjectSettings/layers.json`) names the two assets the project uses: `render_layers` and `physics_layers`. Each field's picker lists only assets of its type (`ref:"Render_Layers"`, `ref:"Physics_Layers"`). An unset field is the essentials plugin's default asset of that type, `assets/rendering/DefaultRenderLayers.asset` and `assets/physics/DefaultPhysicsLayers.asset`, and the built-in names when the essentials plugin is not installed either. A new asset, the default asset and the built-in names are the same:

- render layer 0, `RENDER_LAYER_DEFAULT`, is "Default". A new object is on it
- render layer 31, `RENDER_LAYER_EDITOR`, is "Editor". It is reserved for the editor: thumbnails and the inspector's live previews draw their content on it and their views draw nothing else, so the open scene never shows in them. The picker does not list it
- physics layer 0 is "Default". A new collider is on it

The engine keeps one copy of each active asset's names and registers the copies as the two domains (`plugins/engine/layers_asset.odin`). `layers_sync` brings the copies up to date: each frame calls it, and code that reads names before the first frame can call it too. Each copy follows:

- a change of its field in the Layers setting, from the Project Settings window, an undo or a load
- a change of the asset file on disk
- an edit of the active asset in the inspector, saved or not (`render_layers_preview`, `physics_layers_preview`). Save writes the file, unsaved edits revert on the next editor run

A field that names a missing asset, or an asset of the other type, logs a warning and gives the domain the built-in names.

To give a project its own names:

1. Create an asset with Assets ▸ Create ▸ Render Layers or Assets ▸ Create ▸ Physics Layers
2. Name its layers in the inspector and save it
3. Pick it in the `render_layers` or `physics_layers` field of Project Settings ▸ Layers

Picking another asset there switches every picker of that domain to the new asset's names. The layer bits in scenes do not change, so an object on layer 3 stays on layer 3 under whatever name the new asset gives it.

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

A `u32` field tagged `decor:layers(domain="render")` or `decor:layers(domain="physics")` draws as a dropdown with "Nothing", "Everything" and a checkbox per named layer of the domain. The closed dropdown reads "Nothing", "Everything", the names of the layers that are on (up to three), or "Mixed". The hidden layers do not count: a mask with every listed layer on reads "Everything". "Nothing" sets the mask to 0 and "Everything" to every bit. Each change in the dropdown is one undo step, across the whole selection. The Transform inspector draws its Render Layers row with the same picker (`inspector.layer_mask_field`).
