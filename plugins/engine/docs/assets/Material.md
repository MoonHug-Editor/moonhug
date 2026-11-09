---
title: "Material"
description: "How a surface looks: a built-in Lit or Unlit shader or a custom one, a texture and colour, alpha clipping, faces, transparency, and the Lit block"
weight: 40
tags: ["engine", "assets"]
path: engine/assets
---

How a surface looks. Assets, Create, Material makes a `.mat`. A MeshRenderer, a SpriteRenderer, an Image or a particle system names it.

## Fields

| Field | Default | What it does |
|---|---|---|
| `shader` | Lit | The built-in shader: Lit or Unlit. |
| `custom_shader` | none | A `.glsl` or `.shadergraph` that replaces `shader`. |
| `texture` | none | The main texture. |
| `color` | white | Multiplies the texture. |
| `alpha_clip`, `alpha_cutoff` | off | Cuts out pixels whose alpha is below the cutoff, in shadows too. |
| `render_face` | Front | Which sides of the triangles draw: Front, Back or Both. |
| `surface` | Opaque | Opaque, or Transparent, which blends and draws back to front after the opaque meshes. |
| `refraction` | 0 | Transparent: bends what is seen through it. |
| `lit` | | The Lit block, below. |
| `properties`, `textures` | | A custom shader's property values and extra textures, one row each. |

## The Lit block

Metallic and smoothness, a metallic-roughness map, a normal map and its scale, an occlusion map and strength, an emission map and colour, which goes above 1 for HDR emission, UV scale, offset and clamping, and which UV set each map reads ([Materials](../Materials.md), "The Lit block").

## In the editor

- The Project Inspector edits it, and the change shows at once on everything that uses it.
- Its thumbnail is the material drawn on a square.
