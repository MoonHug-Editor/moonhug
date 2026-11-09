---
title: "Making a timeline"
description: "Build a short timeline in the Sequencer window: show an object, move it with a tween, log when it ends, preview it and play it"
weight: 10
tags: ["sequencer", "guides"]
---

This guide builds a short timeline on its own object: a cube appears at 1 s, moves for a second, and a message is logged at 3 s. It needs any scene with a cube in it.

## 1. The director

1. Create an empty object named `Intro`.
2. Add Component, Playables/PlayableDirector. Leave `manual_start` off, so the timeline plays when the scene starts.
3. With `Intro` selected, open Window, Animation, Sequencer. The window shows the empty timeline.

## 2. Show the cube

1. Add Track, activation. A track object named `activation` appears under `Intro`.
2. Select the track in the legend and set its `target` to the cube in the window's inspector pane.
3. Double-click the track's row at 1 s. A one-second clip appears there.
4. Drag the clip's right edge to 3 s.

The cube is now inactive outside 1 to 3 s.

## 3. Move it

1. Add Track, tween, and set its `target` to the cube.
2. Double-click its row at 1 s.
3. Select the clip. In the inspector pane add an element to `tweens`, pick TweenMoveLocalTo, and set `to` to where the cube should end up.

The cube moves from where it is at 1 s to `to` by 2 s.

## 4. Log the end

1. Add Track, script.
2. Double-click its row at 3 s, select the clip and set its `duration` to 0. A zero-duration clip is an instant.
3. Add an element to `scripts`, pick ScriptLog and set `enter` to `Intro done`.

## 5. Preview and play

1. Turn on Preview and drag the ruler: the cube appears and moves with the playhead. The log message does not print, since scripts never run in the preview.
2. Press Play in the window's toolbar to play the preview from the playhead.
3. Save Scene, then enter play mode. The director starts on its own, and `Intro done` prints in the Console at 3 s.

## 6. Reuse it

`Intro` is ordinary scene content. Save it as a prefab to place the same timeline in other scenes, and override each instance's targets ([Timelines as prefabs](../concepts/TimelinesAsPrefabs.md)).

## See also

- [Sequencer window](../windows/SequencerWindow.md)
- [Playback](../concepts/Playback.md)
