---
title: "ScriptLog"
description: "A script that writes a message to the log when playback enters, stays in or leaves its clip"
weight: 20
tags: ["sequencer", "components"]
---

A script for a [ClipScript](_index.md): writes a message to the log at each phase of its clip. A probe for whether playback got somewhere.

## Properties

| Field | Default | What it does |
|---|---|---|
| `enter` | empty | Logged when playback enters the clip. |
| `tick` | empty | Logged every frame inside the clip. |
| `exit` | empty | Logged when playback leaves the clip. |

## Behavior

- An empty message skips its phase, so one script probes any subset of the three.
- The messages go to the Console in the editor and to stdout in a standalone build.
- Like every script it runs in play mode only.
