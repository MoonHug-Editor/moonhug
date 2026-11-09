---
title: "particles"
description: "CPU particles: the ParticleSystem component with its modules, an edit-mode preview, sub-emitters, trails and a timeline track"
tags: ["particles", "plugin"]
---

The particles plugin simulates particles on the CPU and draws them as camera-facing quads. A ParticleSystem holds the effect's settings as modules: emission, shape, motion and colour over a particle's life, noise, sub-emitters and trails. The selected effect plays in edit mode.

## What it adds

**Components**

- [ParticleSystem](components/ParticleSystem.md) emits, moves and draws particles.
- [TrackParticles](components/TrackParticles.md) and [ClipParticles](components/ClipParticles.md) play a system on a timeline. Need the sequencer plugin.

**Concepts**

- [Simulation](concepts/Simulation.md): what one frame of a system does, sub-emitters, trails, rendering and replay.

[Roadmap](Roadmap.md): which particle modules exist, and how the simulation scales.

## What it needs

- The engine plugin.
- Optional, the sequencer plugin. It adds TrackParticles and ClipParticles, which play a system on a timeline. They live in the plugin's `sequencer` subpackage, which builds only when the sequencer plugin is enabled ([Plugins](/docs/core/Plugins.md)).

## Quick start

1. Add Component, Effects/ParticleSystem on any object. It emits ten particles a second from a cone.
2. Keep it selected: the effect plays in the Scene window, and the Particles overlay pauses, restarts and stops it.
3. Pick a `sprite` and a `material` in the Renderer group, then open the other groups to shape the effect.

## Extending

The plugin declares no attributes and has no registries. Code drives systems through `system_play`, `system_pause`, `system_stop`, `system_reset` and `system_emit_at` ([ParticleSystem](components/ParticleSystem.md), "From code").

## Limits

- CPU only, one quad per particle, billboard or stretched. No mesh particles.
- No collision, no external forces, no texture sheet animation and no lights ([Roadmap](Roadmap.md)).

## Reference

- [API reference](/docs/reference/packages/particles/particles.md) of the `particles` package, and of its [sequencer integration](/docs/reference/packages/particles/sequencer.md).
- Sample: `particles_sample`, `particles_samples.scene`: a fountain, a burst, smoke and snow, one exhibit per feature.
