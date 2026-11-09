---
title: "Sorting"
description: "The order sprites draw in: layer, order in layer, depth, then scene-tree order, with sorting groups folded in"
weight: 20
tags: ["sprites", "concepts"]
---

The order sprites draw in. The code is `sprite_sort.odin`.

## The keys

Sprites draw back to front by four keys, each deciding only when the ones before it tie:

1. `sorting_layer`
2. `order_in_layer`
3. Depth from the camera, farther first.
4. Scene-tree order.

With every layer and order at 0, sprites sort by depth alone. When the depth ties too, sprites draw in scene-tree order, so a subtree never interleaves with its siblings.

## Sorting groups

A [SpriteSortingGroup](../components/SpriteSortingGroup.md) gives its whole subtree one key against everything outside it: the group's layer and order, and the depth of the group's object. Inside, sprites sort by their own keys. Groups nest, each level sorting as a unit inside the one above.

## How the keys are built

- One pass over each loaded scene's tree per view builds every sprite's key, with the groups above it folded in. There is no walk up the ancestors per sprite.
- Each hierarchy level packs into one 64-bit word: layer, order, inverted depth and the tree position, built with the engine's shared `sort_key_word`. Keys compare word by word, so a group's word decides first and its members' words decide among them.
- The tree position makes every key unique, so the order is total and the same every frame.
- Particles and UI use the same packing, so they interleave with sprites in the transparent pass.
