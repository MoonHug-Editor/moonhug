---
title: "TweenPlayer"
description: "Holds a list of authored tween trees on an object"
weight: 10
tags: ["tween", "components"]
---

Holds a list of authored tween trees on an object. It does not play them on its own: game code runs one with `tween_run`.

## Properties

| Field | Default | What it does |
|---|---|---|
| `animations` | empty | The tween trees, each an `Authored` value. |

## In the editor

Each element of `animations` expands into its node's fields and its children, editable in place. An empty element offers Set Type. The Graph button opens the tree in the [Tween Graph](../windows/TweenGraphWindow.md).

## From code

```odin
_, p := engine.transform_get_comp(door, tween.TweenPlayer)
tween.tween_run(&p.animations[0], tween.TweenContext{subject = door})
```

## Limits

- At most 64 per world.
