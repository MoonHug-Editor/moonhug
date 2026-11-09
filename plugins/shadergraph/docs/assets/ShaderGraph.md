---
title: "Shader graph"
description: "A .shadergraph file: blackboard properties, nodes, links and one Surface node, imported to a shader a Material uses like a .glsl"
weight: 10
tags: ["shadergraph", "assets"]
---

A `.shadergraph` file, JSON. The importer generates GLSL from it and compiles it like a hand-written `.glsl`, so a graph and its hand-written twin produce the same shader. Assets, Create, Shader Graph writes an empty one, which is the built-in lit shader.

## The document

- **Blackboard**, the properties. Float, Vector 2, 3 and 4 and Color become the material's property block, in blackboard order. Texture becomes a sampler and a texture row on the material. Names stay as the GLSL member names when they are identifiers, else they are cleaned up.
- **Nodes**: a kind from the palette, a position, and a literal for every input nothing links into. A Property, a Sample Texture and a Normal Map node name the blackboard entry they read.
- **Links**: an output port to an input port. An input takes one link, and a new one replaces it. A link that would close a cycle is refused.
- **Surface**, the one output node. Its inputs are the template's fields: Albedo, Alpha, Normal, Emissive, Metallic, Smoothness and Occlusion. An input nothing links into keeps the template's preset, texture times colour and the vertex normal, so an empty graph is the built-in lit shader.

## The palette

| Category | Nodes |
|---|---|
| Input | Float, Vector 2, Vector 3, Color, UV, Vertex Color, World Position, World Normal, View Direction, Camera Position, Main Texture |
| UV | Tiling And Offset |
| Math | Add, Subtract, Multiply, Divide, Negate, Absolute, One Minus, Floor, Fraction, Min, Max, Power, Saturate, Lerp, Step, Smoothstep, Sine, Cosine |
| Vector | Dot, Cross, Length, Distance, Normalize, Reflect, Fresnel |
| Channel | Split, Combine, Swizzle XY, Swizzle XYZ |
| Blackboard | Property, Sample Texture, Normal Map, one per blackboard entry |

- **Sample Texture** and **Main Texture** decode their texture from sRGB, as colours.
- **Normal Map** reads its texture as data, unpacks it to -1 to 1, and returns the world normal through the template's `perturb_normal`, its Strength scaling the tilt, for the Surface's Normal.
- An unlinked UV on a texture node is the mesh's UVs.

## Import

- Saving reimports the graph and drops its cached shader, so a material on the graph draws with the new shader at once.
- Selecting the file shows its import settings and an Open Shader Graph button.
