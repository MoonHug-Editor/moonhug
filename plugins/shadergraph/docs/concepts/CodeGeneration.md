---
title: "Code generation"
description: "Port types and how they convert, how a graph becomes GLSL, and what a saved graph relies on"
weight: 10
tags: ["shadergraph", "concepts"]
---

How a graph becomes a shader. The code is `codegen.odin` and `nodes.odin`.

## Port types

- Ports are Float, Vec2, Vec3, Vec4 or Dyn. A Dyn port, on the Math nodes, takes the widest type linked into its node, and Float when nothing is linked, so Color times Float is a colour.
- Across a link a float spreads to every component, a wider vector drops its tail, and a narrower one pads with zeros.

## Generating

- `generate` emits only the nodes that reach the Surface node, each once, with one variable per output, `n<id>_<port>`, then assigns the linked Surface fields.
- Unknown kinds, missing properties and cycles are reported per node instead of compiled.
- The result is the body of `surface()` for the engine's surface template, with the property block and samplers the blackboard declares.

## What a saved file relies on

A saved graph relies on each kind's inputs keeping their order in `nodes.odin`. A new input goes at the end of its kind's list.
