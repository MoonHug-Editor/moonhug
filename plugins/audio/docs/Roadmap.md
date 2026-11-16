---
title: "Roadmap"
description: "What the audio plugin does not do yet"
weight: 900
tags: ["audio", "roadmap"]
---

What the audio plugin does not do yet. How it works is in [Playback](concepts/Playback.md).

## Open

- **Compressed clips.** A clip's file is decoded PCM, whether it streams or loads whole, so long music takes its full size on disk. Keeping a clip compressed, on disk and in memory, is not built.
- **Mixer groups and effects.** SDL3_mixer tags tracks, which is the primitive groups would build on.
- **More spatial models.** One logarithmic fade, a balance pan, no Doppler and no reverb.
