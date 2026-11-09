---
title: "Roadmap"
description: "Which particle modules exist and what each lacks, and the steps that keep the simulation fast as particle counts grow"
weight: 900
tags: ["particles", "roadmap"]
---

What the particles plugin does not do yet. How it works is in [Simulation](concepts/Simulation.md).

## Modules

The modules a particle system usually has, and how much of each exists:

| Module | Status |
|---|---|
| Main | Yes. No 3D size or rotation, delta time choice, scaling mode, emitter velocity, stop action, culling mode or ring buffer. |
| Emission | Yes. |
| Shape | Partly. Cone, Sphere, Hemisphere, Circle, Edge, Box and Point. No mesh or sprite shapes, arc, radius thickness or emission texture. |
| Velocity over lifetime | Yes, linear and orbital. No offset and no speed modifier. |
| Limit velocity over lifetime | Speed and dampen. No per-axis limit and no drag. |
| Inherit velocity | No. |
| Lifetime by emitter speed | Yes. |
| Force over lifetime | Yes. |
| Colour and size over lifetime | Yes. |
| Colour and size by speed | Yes. |
| Rotation over lifetime | Angular velocity range. |
| Rotation by speed | Yes. |
| External forces | No. |
| Noise | Strength, frequency and scroll. No octaves, damping, per-axis noise or quality. |
| Collision, triggers | No. |
| Sub emitters | Birth and Death fire the target's bursts at the particle. No collision, trigger or manual triggers, no inheritance, no sub-systems that follow their particle. |
| Texture sheet animation | No. |
| Lights | No. |
| Trails | Ribbons per particle. No ribbon mode across particles, no texture modes and no fade-out after the particle dies. |
| Custom data | No. |
| Renderer | Billboard and stretched billboard. No mesh render mode and no pivots. |

## Scaling steps

The particle store is a `[dynamic]Particle` per system, dead particles leave by swap-remove, and every particle has the same fields. Below 10 000 live particles in total, no change is measurable. The steps below apply in order as counts grow. The thresholds are bandwidth estimates for one core at 60 fps with a 1 ms update budget, not measurements. A timer around `particles_update` on a stress scene confirms them.

1. **Measure first.** A stress scene with a few systems at `max_particles` 50 000, and the update time per frame. Nothing below is worth doing without the number.
2. **Move trails out of `Particle`** (from about 10 000 live particles). `trail: [TRAIL_MAX]Trail_Point` is 256 bytes inline in a row of about 316, so the update loop streams five cache lines per particle to use one, also with trails off. Trails go to a per-system array, used only when `trail_ratio > 0`. The row shrinks to about 64 bytes.
3. **`#soa[dynamic]Particle`** (from about 50 000). The update loop touches only the arrays it reads (position, velocity, life, lifetime). Loops keep the `ps.particles[i].field` form, removal is `unordered_remove_soa`, rendering reads a whole row with `ps.particles[i]`.
4. **Cheaper per-particle math** (from about 200 000). At this count the limit is the curve and gradient sampling per particle per frame and the random numbers at emission, not memory. Sample over-lifetime curves into a small table per system once per frame and index it by life fraction. Batch emission.
5. **Upload size** (same range). Instance data per particle per frame is the GPU-side cost: 48 bytes × 200 000 is 9.6 MB each frame. A smaller instance layout (half floats, packed color) before any update-loop work past this point.

Bitmaps per particle are not a step: every particle has every field, and dead ones are removed, so there is no "which particles have X" question.
