---
title: "Shader Graph"
description: "Node-based surface shaders: a .shadergraph asset of blackboard properties, nodes and links that the importer compiles through the engine's surface template, so a Material uses it like a .glsl"
order: 10
tags: ["rendering", "materials", "plugins"]
---

A shader graph is a surface shader drawn as nodes (plugins/engine/docs/Materials.md "Surface shaders"). The asset is a `.shadergraph` JSON file, the importer turns it into GLSL and compiles it exactly like a hand-written `.glsl`, and a Material names it in `custom_shader`. A graph and its hand-written twin produce the same shader: the generated `surface()` runs inside the same template, lit, shadowed and tonemapped like every other material.

## The document

- **Blackboard**: the properties. Float, Vector 2/3/4 and Color become the material's property block, in blackboard order. Texture becomes a sampler and a texture row on the material. Names are kept as the GLSL member names when they are identifiers, else sanitized.
- **Nodes**: a kind from the palette (nodes.odin), a position, and a literal for every input nothing links into. A Property node, a Sample Texture node and a Normal Map node name the blackboard entry they read.
- **Links**: output port to input port. An input takes one link, a new one replaces it. A link that would close a cycle is refused.
- **Surface**: the one output node, with the template's fields: Albedo, Alpha, Normal, Emissive. An input nothing links into keeps the template's preset (texture × color, the vertex normal), so an empty graph is the built-in lit shader.

## Types

Ports are Float, Vec2, Vec3, Vec4, or Dyn. A Dyn port (the Math nodes) takes the widest type linked into its node, float when nothing is linked, so Color × Float is a color. Across a link, a float spreads to every component, a wider vector drops its tail and a narrower one pads with zeros.

## Codegen

`generate` emits only the nodes that reach the Surface node, each once, one variable per output (`n<id>_<port>`), then assigns the linked Surface fields. Unknown kinds, missing properties and cycles are reported per node instead of compiled.

The Surface node's inputs are Albedo, Alpha, Normal, Emissive, Metallic, Smoothness and Occlusion, the template's Surface fields. An unlinked input keeps the template's preset.

Texture nodes: Sample Texture decodes its texture from sRGB (a color), Main Texture likewise. Normal Map reads its texture as data, unpacks it to -1..1 and returns the world normal through the template's `perturb_normal`, its Strength scaling the tilt, for the Surface's Normal. An unlinked UV on a texture node is the mesh's uvs (`frag_uv`).

## Editor

Assets > Create > Shader Graph writes an empty graph. Double-clicking a `.shadergraph` in the Project view (or Enter on it) opens it in the Shader Graph window (`editor/shadergraph_window.odin`), through the open handler the plugin registers with `asset_open_handler_add`. Selecting it shows the importer settings and an Open Shader Graph button that does the same (`editor/shadergraph_inspector.odin`). Each graph opens its own instance of the window, so graphs are edited side by side, and an instance edits its graph's shared asset document, the one File/Save, the tab menu and undo reach ([Views](../../../docs/core/Views.md)). Unsaved edits stay in the document, so closing an instance and opening the graph again keeps them.

- **Toolbar**: the asset path, and ` *` while the graph has unsaved edits. A save reimports the graph and drops its cached shader, so a material on the graph draws with the new shader at once. A refused link shows a notice here for a few seconds.
- **Blackboard** (left): one row per property with its name, kind and default value (a drag per component, a color picker for Color, nothing for Texture). A rename lands when the name field is left, and every node that reads the property follows it. An empty or taken name is ignored. Add opens a list of the kinds, the x button removes a property and the nodes that read it.
- **Node** (left, under the blackboard): the selected node's unlinked inputs as drags by port type (a color picker on the Color node). A linked input shows as linked.
- **Canvas** (middle): one node per graph node on the shared node canvas (`moonhug/editor/node_canvas`). The title is the kind, the property name for a Property node, `Sample <name>` for a Sample Texture node. Each input is a row with its port and its literal while unlinked, each output a row with its port on the right edge. Ports and links are colored by port type, and a node the generator reports an error for draws red.
- Dragging a node moves it. Dragging from an output port to an input port of another node links them through `graph_link`, which replaces the input's old link and refuses a cycle. Clicking a link selects it.
- Right-click on empty canvas opens the add menu: the palette by category (without Property and Sample Texture, and without Surface while the graph has one), then one entry per blackboard property (`Property: <name>`, or `Sample Texture: <name>` and `Normal Map: <name>` for a texture). The new node lands where the click was.
- Delete or Backspace removes the selected link, else the selected node. The Surface node is never removed.
- **GLSL** (right): the output of `generate`, or its errors, rebuilt after every recorded edit.

Every edit is one undo step. The window marks the document touched on each edit, and once no widget is active it serializes the graph to JSON and compares it with the last recorded snapshot. A difference pushes one undo step on the asset holding both snapshots, so a node drag or a value drag records once on release. Undo and redo replace the document's instance, whichever graph the window shows, and the window regenerates from the new one.

## Files

- `shadergraph.odin`: the document, its edits, load and save
- `nodes.odin`: the node table, the palette and the contract a saved file relies on (a kind's inputs keep their order)
- `codegen.odin`: the GLSL
- `editor/shadergraph_importer.odin`: the importer and the reimport on edit
- `editor/shadergraph_window.odin`: the window
- `editor/shadergraph_inspector.odin`: the Open Shader Graph button
