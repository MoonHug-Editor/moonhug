---
title: "SpriteSortingGroup"
description: "Makes every sprite under its object sort as one unit against sprites outside it"
weight: 20
tags: ["sprites", "components"]
---

Makes every sprite under its object sort as one unit against sprites outside it. Inside the group, sprites keep sorting among themselves by their own keys.

## Example

A character made of several sprites that must not interleave with another character standing in front of it:

```
Enemy           SpriteSortingGroup: sorting_layer 1
├── Body        SpriteRenderer: order_in_layer 0
└── Sword       SpriteRenderer: order_in_layer 1
```

## Properties

| Field | Default | What it does |
|---|---|---|
| `sorting_layer` | 0 | The group's first sort key against sprites outside it. |
| `order_in_layer` | 0 | The group's second sort key. |

## Behavior

- Against outside sprites the group sorts by its own layer and order and the depth of the group's object.
- Groups nest. An inner group sorts as one unit inside its outer group, up to 7 levels deep.
- A disabled group stops grouping.

## See also

- [Sorting](../concepts/Sorting.md)
