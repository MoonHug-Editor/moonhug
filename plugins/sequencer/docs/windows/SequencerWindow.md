---
title: "Sequencer window"
description: "Edits the timeline of the selected object: tracks, clips and their fields, with an edit-mode preview"
weight: 10
tags: ["sequencer", "editor", "windows"]
---

Edits the timeline of the selected object, or of its nearest ancestor with a [PlayableDirector](../components/PlayableDirector.md), and previews it without entering play mode. Open it from Window, Animation, Sequencer.

## Layout

- **Toolbar.** Preview, then To Start, Frame Backward, Play or Pause, Frame Forward and To End. A frame is the engine's fixed tick. Then the time and the duration, Save Scene, and Add Track with every registered track kind.
- **Legend.** One row per track: mute, name, and a menu with Add Clip at Playhead, Rename and Remove Track.
- **Canvas.** A ruler in seconds over one row per track, with the clips as blocks.
- **Inspector pane.** The selected track and clip, each with its kind component, drawn by the regular inspector. The `ref:` and `ext:` tags filter the pickers, so the window knows nothing about any kind.

## Editing

- Double-click an empty spot on a row to add a clip there, or right-click it for Add Clip Here.
- Drag a clip's body to move it and an edge to resize it, in tenths of a second.
- Right-click a clip for Duplicate and Delete. Delete or Backspace deletes the selected clip.
- The wheel zooms the canvas.

Every edit is an ordinary scene edit: field edits are component edits, and adding, duplicating and removing tracks and clips creates and deletes objects through the same undo the hierarchy uses. Save Scene saves the scene the timeline is in.

## Preview

- With Preview on, the playhead poses the scene and game render, and the world keeps its own values in between, so nothing leaks into saves or undo.
- Dragging the ruler or a paused playhead scrubs: no crossings fire, and stateful tracks replay to the time. Play advances the preview with crossings, so audio sounds live. Scripts never run in the preview.
- Entering play mode ends the preview and rewinds the director, so every track starts together from 0. Play is deferred one frame, so the preview's restore renders before the scene is captured. While playing, play mode drives the director and the preview controls are disabled. Editing stays available.

## Keys

| Key | Command |
|---|---|
| Delete, Backspace | Sequencer/Delete Clip |

## See also

- [Making a timeline](../guides/MakingATimeline.md)
- [Playback](../concepts/Playback.md), the evaluation modes the preview uses.
