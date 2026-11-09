---
title: "Roadmap"
description: "What the audio plugin does not do yet"
weight: 900
tags: ["audio", "roadmap"]
---

What the audio plugin does not do yet. How it works is in [Playback](concepts/Playback.md).

## Open

- **Load types.** Clips decode whole into memory. Streaming long music and keeping clips compressed in memory are not built.
- **Mixer groups and effects.** SDL3_mixer tags tracks, which is the primitive groups would build on.
- **More spatial models.** One logarithmic fade, a balance pan, no Doppler and no reverb.
