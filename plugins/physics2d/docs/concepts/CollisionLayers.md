---
title: "Collision layers"
description: "Which 2D colliders collide: each collider's layers, the matrix in the layers asset, and include and exclude overrides on colliders and bodies"
weight: 20
tags: ["physics2d", "concepts"]
---

Which colliders collide. The 2D colliders have collision layers of their own, apart from the render layers and from physics3d's: layer domain `"physics2d"`. The code is `layers.odin`.

## A collider's layers

Every collider has `layers`, the layers it is on, and a new collider is on layer 0. Several layers are allowed.

## The mask

A collider's mask is what it collides with:

1. The [Physics 2D Layers](../assets/Physics2DLayers.md) matrix's rows for the collider's layers.
2. Plus the `include` layers of the collider's `layer_overrides` and of its Rigidbody2D's.
3. Minus the `exclude` layers of both.

So an override on a body applies to every collider attached to it.

## The rule

Two colliders collide when `(a.layers & b.mask) != 0 && (b.layers & a.mask) != 0`, box2d's own rule, so an exclude on either side wins. The same test decides whether a trigger reports an overlap.

## Live edits

The layers and the mask become the box2d shape filter's `categoryBits` and `maskBits` when the shape is built. Each physics step writes a changed value into the live shape, so an edit of the matrix, a collider's layers or the overrides applies on the next step.
