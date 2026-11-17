---
title: "AudioHighPassFilter"
description: "Thins out the AudioSource on its object: what is below the cutoff is turned down"
weight: 31
tags: ["audio", "components"]
---

Thins out the [AudioSource](AudioSource.md) on its object: what plays below `cutoff` is turned down, before the source's mixer group. A phone line, a small speaker.

## Properties

| Field | Default | What it does |
|---|---|---|
| `cutoff` | 5000 Hz | What is below it is thinned out. |
| `resonance` | 1 | 1 is a plain slope, more rings at the cutoff. |

## Behavior

- It filters the source's own track, before an [AudioLowPassFilter](AudioLowPassFilter.md) on the same object. Edits are heard at once.
- Disabled, it lets the sound through.

## Limits

- Timeline voices of the source and one-shots are not filtered.
