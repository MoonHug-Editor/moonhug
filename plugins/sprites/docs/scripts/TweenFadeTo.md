---
title: "TweenFadeTo"
description: "A timeline tween that fades a SpriteRenderer's alpha to a value over its clip"
weight: 10
tags: ["sprites", "sequencer", "scripts"]
---

A tween for a timeline's [ClipTween](/plugins/sequencer/docs/components/ClipTween/_index.md): fades a [SpriteRenderer](../components/SpriteRenderer.md)'s alpha from where it is at the clip's start to `to`. Needs the sequencer plugin.

## Properties

| Field | Default | What it does |
|---|---|---|
| `capture` | Play | When the start alpha is taken again: Play once per play session, Enter on every pass into the clip. |
| `target` | none | The SpriteRenderer to fade. |
| `to` | 0 | The alpha at the clip's end. The colour stays. |

## Behavior

- It imports only `sequencer/core`, and the prebuild adds it to the sequencer's TweenUnion, so the sequencer names no sprites type ([Scripts and tweens](/plugins/sequencer/docs/concepts/ScriptsAndTweens.md)).
