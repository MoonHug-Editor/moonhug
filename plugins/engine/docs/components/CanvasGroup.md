---
title: "CanvasGroup"
description: "Settings for a whole subtree of UI: how opaque it draws, whether its controls can be used, whether the pointer hits it"
weight: 145
tags: ["engine", "ui", "components"]
path: engine/components
---

Settings for everything under its node, the node included.

## Example

```
Shop           RectTransform, CanvasGroup alpha 0.35, interactable off
├── Heading    RectTransform, CanvasRenderer, Text
└── Buy        RectTransform, CanvasRenderer, UiShape, Button
```

The whole panel is faded and its button cannot be pressed. Setting `alpha` back to 1 and `interactable` on brings it back, with no change to any node under it.

## Properties

| Field | Default | What it does |
|---|---|---|
| `alpha` | 1 | How opaque the subtree draws: multiplies the alpha of every graphic under it. 0 draws nothing. |
| `interactable` | on | Off, the controls under it cannot be used and show as disabled. |
| `blocks_raycasts` | on | Off, the pointer passes through everything under it to what is behind. |
| `ignore_parent_groups` | off | The groups above this one do not count for what is under it. |

## Behavior

- Groups nest. A node takes the alpha of every group above it multiplied, and is interactable and hit by the pointer only when every group above it says so.
- A faded subtree still takes the pointer. Turn `blocks_raycasts` off to let clicks through it.
- A subtree that is not interactable still blocks the pointer: a press on its disabled button does not reach what is behind.
- Fading a panel in or out is changing one number: `alpha` from 0 to 1.
