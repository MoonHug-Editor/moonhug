---
title: "Timelines as prefabs"
description: "A timeline is a transform subtree under a PlayableDirector, so the prefab system gives reuse, overrides, variants and nesting"
weight: 10
tags: ["sequencer", "concepts", "prefabs"]
---

A timeline is not a document of its own. It is a transform subtree: an object with a [PlayableDirector](../components/PlayableDirector.md), track objects as its children and clip objects under them. Saved as a prefab, it is a timeline asset, and everything the prefab system does is a timeline feature.

| Timeline concept | What gives it |
|---|---|
| Timeline asset | a prefab whose root has a director |
| Reuse in a scene | a prefab instance |
| Per-instance edits | prefab overrides, of targets, times or anything else |
| Timeline variant | a prefab variant |
| Nested timeline | a prefab instance under a control clip |
| Embedded timeline | plain scene content |
| Clip identity | local ids, so undo, overrides and multi-editing apply |
| Track kind | a component, keyed by its type |

## The parts

- **The director** sits on the root object and holds playback: wrap, speed, start and length.
- **A track object** carries [TimelineTrack](../components/TimelineTrack.md), which every track has, and its kind component, which says what the track drives and holds its target: `TrackActivation.target`, `TrackAudio.source`. A kind that drives nothing outside its clips has no target field, and one that drives two things has two.
- **A clip object** carries [TimelineClip](../components/TimelineClip.md), its span, and the kind's clip component, its payload: `ClipAudio.clip`, `ClipScript.scripts`. A clip whose span is the whole instruction has an empty clip component.
- Names are the objects' names. Track order is the order of the director's children. Clip order comes from the start times.

## Why

- **No second format.** Saving, loading, undo, the hierarchy, the inspector, copy and paste and multi-editing all work on timelines because a timeline is ordinary scene content.
- **Overrides are the binding.** A timeline's targets are authored inside the prefab and changed per instance as overrides. There is no binding table and no exposed-reference table to keep in step with the content.
- **Kinds stay apart.** Each kind's component holds what that kind needs, with a `ref:` tag that filters its picker, so no shared field means different things for different kinds, and the Sequencer window needs no knowledge of any kind.

## See also

- [Playback](Playback.md), how the director plays the tree.
- [Nested Prefabs](/plugins/engine/docs/NestedPrefabs.md), the prefab system itself.
