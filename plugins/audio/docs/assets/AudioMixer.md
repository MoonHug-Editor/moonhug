---
title: "Audio Mixer"
description: "A tree of groups that sounds play through, each with a volume, a mute and effects: low pass, high pass, duck"
weight: 20
tags: ["audio", "assets", "mixer"]
---

A `.mixer` file: a tree of groups that sounds play through. An [AudioSource](../components/AudioSource.md) picks a group in `output`, and its sound goes through that group, then its parent, up to the Master. Each group on the way applies its volume and its effects.

Make one with Assets > Create > Audio Mixer. A new mixer has a Master group.

## Example

```
Main.mixer
└── Master
    ├── Music        Duck: listens to Dialogue
    ├── Dialogue
    └── Effects      Low Pass 2000 Hz while underwater
```

Music, voices and effects each get a group, so a settings menu turns each kind of sound up or down with one call, and music drops under dialogue on its own.

## Groups

| Field | Default | What it does |
|---|---|---|
| `name` | New Group | What the group is called in pickers: `Main / Music`. |
| `volume` | 0 dB | 0 leaves the sound as it is, -6 about halves it, -80 is silence, up to +20. |
| `mute` | off | Silences the group and everything under it. |
| `effects` | none | Applied in order, after the volume. |

A group's id is minted when it is added and never reused, so a source's `output` keeps its group when other groups are renamed, moved or removed.

## Effects

| Effect | Fields | What it does |
|---|---|---|
| Low Pass | `cutoff` 5000 Hz, `resonance` 1 | Lets through what is below the cutoff and muffles what is above it. |
| High Pass | `cutoff` 5000 Hz, `resonance` 1 | Lets through what is above the cutoff and thins out what is below it. |
| Duck | listens to, `threshold` -30 dB, `ratio` 4, `attack` 50 ms, `release` 400 ms | Turns this group down while the group it listens to plays. Above the threshold, each `ratio` dB louder the other group plays turns this one down `ratio - 1` dB more. |

A zero field of an effect stands for its default, so an effect just picked from the list works as it is. A resonance above 1 rings at the cutoff.

## In the editor

- The Project Inspector shows the groups as a tree, each with its volume. A click selects a group, and its fields and effects show under the tree.
- Add Group puts a new group under the selected one. Remove takes away the selected group and the groups under it. The Master stays.
- Drag a group onto another to move it under that one.
- The Project window unfolds a mixer to its groups, and an AudioSource's `output` picker lists them.
- Every edit is heard at once, saved or not.

## From code

```odin
import "moonhug:packages/audio"

// A settings menu's music slider, in dB, while the game runs.
audio.mixer_set_volume(music_group, -12)
db := audio.mixer_volume(music_group)

// A sound with no component, through a group.
audio.play_clip(click_sound, output = ui_group)
```

`music_group` is a `PPtr` field set in the inspector, like a source's `output`. `mixer_set_volume` leaves the asset as it is: play stopping, or `mixer_clear_volumes`, goes back to its volumes. `mixer_level` gives how loud a group plays now, in dB.

## How it plays

- A mixer loads the first time a sound plays through one of its groups. Each group a sound plays through is a group of the SDL3_mixer mixer, and its tracks are mixed into it.
- A group's audio goes through its own volume and effects, then each parent's. A filter or a volume on a sum of sounds is the same as on each sound, so each group carries the whole path to the Master, and a parent with no sound of its own costs nothing.
- Once per mix pass each group's level is measured, and each Duck moves toward the level of the group it listens to.
- A mixer removed from the project plays no more: its sounds go straight to the output.

## Limits

- No snapshots, no sends and no reverb or echo.
- One mixer does not route into another's group.
- Meters show only through `mixer_level`, not in the editor.
