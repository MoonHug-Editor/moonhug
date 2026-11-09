---
title: "ClipAudio"
description: "Makes a timeline clip an audio clip: the sound a TrackAudio plays for the clip's span"
weight: 40
tags: ["audio", "sequencer", "components"]
---

Makes a timeline clip an audio clip: the sound a [TrackAudio](TrackAudio.md) plays for the clip's span. Needs the sequencer plugin.

## Example

```
Intro                   PlayableDirector
└── Music               TimelineTrack + TrackAudio, source MusicSource
    ├── theme           TimelineClip + ClipAudio, clip Theme.ogg, 0 to 8 s, ease_out 2
    └── sting           TimelineClip + ClipAudio, clip Sting.wav, 7 to 9 s
```

The theme fades out over its last two seconds while the sting fades in over it.

## Properties

| Field | Default | What it does |
|---|---|---|
| `clip` | none | The audio file: `.mp3`, `.wav` or `.ogg`. |
