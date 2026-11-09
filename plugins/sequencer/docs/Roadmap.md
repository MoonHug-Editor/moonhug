---
title: "Roadmap"
description: "What is open for the sequencer plugin and what is not planned"
weight: 900
tags: ["sequencer", "roadmap"]
---

What the sequencer plugin does not do yet, and what it will not do. How it works, and why, is on its concept pages: [Timelines as prefabs](concepts/TimelinesAsPrefabs.md), [Playback](concepts/Playback.md) and [Scripts and tweens](concepts/ScriptsAndTweens.md).

## Open

- **Weight for kinds that are not poses.** Every kind gets a clip's weight. Audio scales volume by it, activation and scripts ignore it. What a fractional weight means for an instant event is decided once real timelines cross-fade ([TimelineAnimator roadmap](/plugins/animation/docs/Roadmap.md)).
- **One tween vocabulary.** The clip tweens and the tween plugin's tweens are separate, and the generated union is where they would meet if they unify.

## Not planned

- Composite tweens inside a clip. The timeline is the container: a clip holds parallel tweens and consecutive clips are a sequence.
- A timeline document format of its own. A timeline is scene content, and a prefab when it is shared.
- A binding table. A track's target is its own field, and an instance changes it with a prefab override.
