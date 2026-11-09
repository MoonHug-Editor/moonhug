---
title: "ScriptSetActive"
description: "A script that sets an object active or inactive for its clip's span and switches it back when the span ends"
weight: 10
tags: ["sequencer", "components"]
---

A script for a [ClipScript](_index.md): sets its target active or inactive when playback enters the clip, and switches it back when playback leaves.

## Properties

| Field | Default | What it does |
|---|---|---|
| `target` | none | The object to switch, in the same file. |
| `active` | off | The state for the span. On enter the target gets `active`, on exit the opposite. |

## Behavior

- It does what a [TrackActivation](../TrackActivation.md) does, as one step of a script clip, so it can sit beside other scripts on the same clip.
- Like every script it runs in play mode only. Scrubbing and the preview do not switch the target. Use an activation track to see the switch while scrubbing.
