---
title: "AudioLowPassFilter"
description: "Muffles the AudioSource on its object: what is above the cutoff is turned down"
weight: 30
tags: ["audio", "components"]
---

Muffles the [AudioSource](AudioSource.md) on its object: what plays above `cutoff` is turned down, before the source's mixer group. A radio's tinny voice, a sound heard through a wall.

## Example

```
Radio           AudioSource: clip news.ogg
                AudioLowPassFilter: cutoff 3000
                AudioHighPassFilter: cutoff 400
```

## Properties

| Field | Default | What it does |
|---|---|---|
| `cutoff` | 5000 Hz | What is above it is muffled. |
| `resonance` | 1 | 1 is a plain slope, more rings at the cutoff. |

## Behavior

- It filters the source's own track. Edits are heard at once, also in the editor with the source's Play button.
- Disabled, it lets the sound through.
- With an [AudioHighPassFilter](AudioHighPassFilter.md) on the same object, the high pass runs first. An [AudioOcclusion](../extends/physics3d/components/AudioOcclusion.md) muffles after both.

## Limits

- Timeline voices of the source and one-shots are not filtered.
