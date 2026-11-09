---
title: "Shader"
description: "A hand-written .glsl surface or fragment shader that a Material uses, compiled for every backend, with its property block and textures"
weight: 30
tags: ["engine", "assets"]
path: engine/assets
---

A `.glsl` file. A [Material](Material.md) names it in `custom_shader` to draw with it instead of the built-in shaders. A surface shader fills the engine's surface template, so it is lit and shadowed like the built-in Lit shader. A shader graph from the shadergraph plugin compiles the same way.

## Import

- The importer compiles the shader for every backend and reads its property block, the uniforms at `set = 3, binding = 1`, and its samplers. A Material then shows one row per property and per texture.
- Saving the file reimports it, and materials on it draw with the new shader at once.
- It has no import settings.

## See also

- [Materials](../Materials.md), "Custom user shaders", "Surface shaders" and "Property blocks".
