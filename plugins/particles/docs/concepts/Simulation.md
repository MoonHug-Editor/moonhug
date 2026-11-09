---
title: "Simulation"
description: "What one frame of a particle system does, how sub-emitters and trails work, how particles render, and how a seeded effect replays"
weight: 10
tags: ["particles", "concepts"]
---

How a [ParticleSystem](../components/ParticleSystem.md) runs. The code is `particles.odin`.

## One frame

`particles_tick` runs every frame (`@(update)`) and calls `system_tick` for each enabled system. `system_tick` is public, so the tests drive systems without a frame loop. Each advance:

1. Ages the particles and removes the dead ones.
2. Applies gravity, the limit on speed and the velocity curves. Gravity is a world force, turned into the emitter's axes for a Local system.
3. Moves each particle and spins it.
4. Emits: by rate over time, by the distance the emitter moved, and the bursts whose time the cycle crossed this frame, also across a loop.

`simulation_speed` scales the advance, `prewarm` runs one whole cycle in small steps on a looping system's first frame, and `start_delay` holds emission back.

## Replay

A system draws its random numbers from its own seeded stream. With a nonzero `random_seed`, `system_reset` followed by the same advances gives the same particles every time. The timeline's particles track relies on it: scrubbing resets the system and advances it in fixed steps to the time, so a scrub shows the same frame as play.

## Sub-emitters

- A sub-emitter entry names a target system, a trigger and a probability. When a particle is born or dies, the target fires its own bursts once at that particle's position. The target authors what each trigger emits as bursts.
- Every target is marked once per frame (`mark_sub_targets`) and never emits on its own timeline, only from triggers or `system_emit_at`. The preview's Self scope lifts that rule, to try a target alone.
- Chains and a system targeting itself are cut off at a fixed depth.
- A target draws from its own random stream, so seeded replay stays exact.

## Trails

- A trailing particle records a point each time it has moved `trail_min_distance`, into a fixed ring of points, dropping the oldest. Points expire after `trail_lifetime` times the particle's lifetime, and the trail dies with its particle.
- A trail draws as one strip facing the camera through its points and the particle's head. Neighbouring segments share their edge, and the texture stretches once along the whole trail.

## Rendering

- The plugin's `@(render_collector)` emits one quad per particle. Camera right and up come from the view, and the particle's roll turns them. A Stretched quad aligns to the velocity instead.
- A sliced sprite's UVs come from its slice rectangle.
- Sort keys use `engine.sort_key_word(layer, order, depth, seq)`, so particles interleave with sprites in the transparent pass.
- The edit-mode preview renders in every window, the Game window included. With several scenes open, every enabled camera renders, so a second scene's camera shows the preview too.

## Curves

The start values and every curve field use the engine's `MinMax_Curve`, `Curve` and `Gradient`, with the inspector drawers the engine ships for them. An empty curve or gradient evaluates as off: a curve to its empty value, a gradient to white.
