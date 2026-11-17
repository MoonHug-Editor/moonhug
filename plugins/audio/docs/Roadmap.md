---
title: "Roadmap"
description: "What the audio plugin does not do yet"
weight: 900
tags: ["audio", "roadmap"]
---

What the audio plugin does not do yet. How it works is in [Playback](concepts/Playback.md).

## Open

- **Compressed clips.** A clip's file is decoded PCM, whether it streams or loads whole, so long music takes its full size on disk. Keeping a clip compressed, on disk and in memory, is not built.
- **More of the mixer.** Snapshots, sends, reverb and echo, a group of one mixer routed into another's, and an Audio Mixer window with a strip and a live meter per group ([Audio Mixer](assets/AudioMixer.md)).
- **Filters on every voice.** A source's filter components filter its own track, not its timeline voices or one-shots.
- **More spatial models.** One logarithmic fade, a balance pan, no Doppler and no reverb.
