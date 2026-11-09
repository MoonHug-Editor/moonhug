---
title: "shadergraph"
description: "Node-based surface shaders: a .shadergraph asset compiled to GLSL through the engine's surface template, edited in the Shader Graph window"
tags: ["shadergraph", "rendering", "plugin"]
---

The shadergraph plugin draws surface shaders as nodes. A `.shadergraph` asset holds properties, nodes and links, the importer turns it into GLSL and compiles it exactly like a hand-written `.glsl`, and a Material names it in `custom_shader`. The generated `surface()` runs inside the engine's surface template, so a graph is lit, shadowed and tonemapped like every other material ([Materials](/plugins/engine/docs/Materials.md), "Surface shaders").

## What it adds

**Assets**

- [Shader graph](assets/ShaderGraph.md): the `.shadergraph` file, its properties, nodes, links and Surface node, and the node palette.

**Windows**

- [Shader Graph](windows/ShaderGraphWindow.md): edits a graph on a node canvas with its properties, the selected node's inputs and the generated GLSL.

**Concepts**

- [Code generation](concepts/CodeGeneration.md): port types, how a graph becomes GLSL, and what a saved file relies on.

## What it needs

- The engine plugin, whose material system and surface template compile the generated shader.

## Quick start

1. Assets, Create, Shader Graph.
2. Double-click it to open the Shader Graph window. Right-click the canvas to add nodes, and drag from an output port to an input port to link them into the Surface node.
3. Save, then pick the graph in a Material's `custom_shader`.

## Extending

The plugin declares no attributes and has no registries. New node kinds are entries in the palette in `nodes.odin`.

## Reference

- [API reference](/docs/reference/packages/shadergraph/shadergraph.md) of the `shadergraph` package.
