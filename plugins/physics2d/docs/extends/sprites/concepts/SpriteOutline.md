---
title: "Sprite outline"
description: "A PolygonCollider2D added to a sprite starts as the outline of the sprite's opaque pixels"
weight: 10
tags: ["physics2d", "sprites", "concepts"]
---

A [PolygonCollider2D](../../../../components/PolygonCollider2D.md) added in the editor to an object with a SpriteRenderer starts as the outline of the sprite's opaque pixels. The code is the plugin's `sprites` subpackage, which builds only with the sprites plugin installed.

## How the outline is made

1. The opaque pixels of the sprite's rect, alpha above 127, form a mask.
2. Marching squares traces the mask's boundaries as loops.
3. The longest loop is kept, so a sprite with several parts gets its largest.
4. Points that a straight line covers within 2 pixels are dropped.
5. The points are put in the collider's space: pixels over the texture's pixels per unit, around the sprite's pivot, y up.

## When it applies

- When the collider is added in the editor, and when it is reset.
- Without a SpriteRenderer with a sprite, with a texture that cannot be read, or with nothing opaque in the sprite's rect, the collider starts as five points on a circle, as it does without the sprites plugin.

## See also

- [sprite_outline in the API reference](/docs/reference/packages/physics2d/sprites.md#sprite_outline), the outline proc with a link to the code.
