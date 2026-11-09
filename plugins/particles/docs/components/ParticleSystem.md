---
title: "ParticleSystem"
description: "Emits, moves and draws particles: the main settings and every module, the edit-mode preview and the playback API"
weight: 10
tags: ["particles", "components"]
---

Emits, moves and draws particles from its object. Its settings are grouped into modules, and a module is off while its fields hold zero.

## Example

A fountain: a narrow cone shooting upward, pulled down by gravity, fading out.

```
Fountain        ParticleSystem: shape Cone, shape_angle 10, start_speed 8, gravity_modifier 1,
                rate 60, color_over_life white to transparent
```

## Main

| Field | Default | What it does |
|---|---|---|
| `duration` | 5 | The emission cycle in seconds. |
| `looping` | on | Starts the cycle again when it ends. |
| `prewarm` | off | A looping system starts as if one cycle already ran. |
| `start_delay` | 0 | Seconds before the first cycle starts. |
| `start_lifetime` | 5 | How long a particle lives, in seconds. |
| `start_speed` | 5 | A new particle's speed along its emission direction. |
| `start_size` | 1 | A new particle's size in world units. |
| `start_rotation` | 0 | A new particle's roll in degrees. |
| `flip_rotation` | 0 | The fraction of particles, 0 to 1, that spin the other way. |
| `color_a`, `color_b` | white | A new particle's colour, random between the two. |
| `gravity_modifier` | 0 | How much of the world's gravity pulls on particles. |
| `sim_space` | Local | Local moves particles with the emitter. World leaves them behind. |
| `simulation_speed` | 1 | The playback speed. 0 runs at 1. |
| `max_particles` | 1000 | No new particle spawns while this many are alive. |
| `random_seed` | 0 | 0 draws a fresh seed at each reset. Any other value replays the exact same effect after `system_reset`. |
| `manual_start` | off | On waits for `system_play` instead of playing when the scene starts. |

The four start values are curves of four kinds: a constant, a random range, a curve over the cycle, or random between two curves.

## Emission

| Field | Default | What it does |
|---|---|---|
| `rate` | 10 | Particles per second. |
| `rate_over_distance` | 0 | Particles per world unit the emitter moves. |
| `bursts` | empty | Each burst emits between `count_min` and `count_max` particles at `time` in the cycle, `cycles` times `interval` seconds apart, each with chance `probability`. |

## Shape

Particles leave along the object's local +Z unless the shape says otherwise.

| Field | Default | What it does |
|---|---|---|
| `shape` | Cone | Cone, Sphere, Hemisphere, Circle, Edge, Box or Point. |
| `shape_radius` | 1 | The cone's base, the sphere's, hemisphere's and circle's radius, the edge's half length. |
| `shape_angle` | 25 | The cone's spread, in degrees from its axis. |
| `shape_box` | 1, 1, 1 | The box's size. |
| `randomize_direction` | 0 | Blends each direction toward a random one, 0 to 1. |
| `spherize_direction` | 0 | Blends each direction toward straight out from the center, 0 to 1. |

A Sphere emits outward from a random point inside it, a Hemisphere does the same on its +Z half, a Circle emits outward in the XY plane, and Edge and Box emit along +Z.

## Over a particle's life

Each curve is evaluated at the particle's age divided by its lifetime, and an empty curve is off.

| Field | What it does |
|---|---|
| `velocity_x`, `velocity_y`, `velocity_z` | Adds velocity in the emitter's axes. |
| `orbital_x`, `orbital_y`, `orbital_z` | Turns particles around the emitter's axes, in degrees per second. |
| `limit_speed`, `limit_dampen` | Speed above `limit_speed` decays toward it by `limit_dampen` each 60th of a second. 0 is off. |
| `force_x`, `force_y`, `force_z` | Accelerates particles in the emitter's axes. |
| `angular_velocity_min`, `angular_velocity_max` | Spin in degrees per second, random between the two. |
| `color_over_life` | A gradient multiplied into the start colour. |
| `size_over_life` | A curve multiplied into the start size. |

## By speed

Each curve is evaluated at a speed remapped from its `_min` to its `_max` field onto 0 to 1.

| Field | What it does |
|---|---|
| `lifetime_by_speed` | Multiplies a new particle's lifetime, by the emitter's speed. |
| `rotation_by_speed` | Adds spin in degrees per second, by the particle's speed. |
| `color_by_speed` | Multiplies the colour, by the particle's speed. |
| `size_by_speed` | Multiplies the size, by the particle's speed. |

## Noise

| Field | Default | What it does |
|---|---|---|
| `noise_strength` | 0 | How far smooth noise moves particles, in world units per second. 0 is off. |
| `noise_frequency` | 0 | The noise's scale. 0 behaves as 1. |
| `noise_scroll_speed` | 0 | How fast the noise field moves over time. |

## Sub emitters

`sub_emitters` lists other ParticleSystems in the same file, each with a `trigger` and a `probability`. When one of this system's particles is born or dies, the target fires its own bursts once at the particle's position. A target never emits on its own, only from triggers ([Simulation](../concepts/Simulation.md), "Sub-emitters").

## Trails

| Field | Default | What it does |
|---|---|---|
| `trail_ratio` | 0 | The fraction of particles that leave a trail, 0 to 1. 0 is off. |
| `trail_lifetime` | 0 | How long a trail point lives, as a multiple of the particle's lifetime. |
| `trail_min_distance` | 0 | The distance between recorded points. |
| `trail_width_over` | empty | The width along the trail, times the particle's size. Empty is 1. |
| `trail_color_over` | empty | The colour along the trail, times the particle's colour. Empty is white. |
| `trail_sprite`, `trail_material` | empty | The trail's own look. Empty uses the particle's. The essentials plugin ships `textures/trail.png`, a soft white band. |

## Renderer

| Field | Default | What it does |
|---|---|---|
| `sprite` | none | The texture, or one sprite of a sliced texture. |
| `material` | none | The material the quads draw with. |
| `render_mode` | Billboard | Billboard faces the camera. Stretched aligns the quad to the particle's velocity. |
| `stretch_length_scale` | 0 | A stretched quad's length as a multiple of its size. 0 behaves as 1. |
| `stretch_speed_scale` | 0 | Extra length per unit of speed. |
| `sorting_layer`, `order_in_layer` | 0 | Where the particles sort among sprites in the transparent pass. |

## Behavior

- A system plays when the scene starts unless `manual_start` is on, and is simulated every frame ([Simulation](../concepts/Simulation.md)).
- Zero means off for every module, so a field missing from a scene file loads as off. The exceptions: `simulation_speed`, `noise_frequency` and `stretch_length_scale` treat 0 as 1, and `random_seed` 0 means a fresh seed.

## In the editor

- The inspector draws the main fields flat, then one collapsing group per module with a checkbox. Ticking a group fills in working values, unticking it clears them, since a module has no separate enabled flag. Every row has the usual undo, multi-editing and prefab overrides. Bursts do not edit across a multi-selection.
- **Preview.** The selected effect plays in edit mode: the whole ParticleSystem hierarchy from its root, sub-emitter targets included, every frame the inspector draws. Selecting another system restarts it, deselecting clears it. Play mode owns playback, so the preview stands down there.
- **Particles overlay** in the Scene window: Pause or Play, Restart, Stop, the scope, the time and the particle count. The scope is Root for the whole effect, Self & Children for the selected subtree, or Self for the selected system alone, where a sub-emitter target plays on its own timeline and the system's own sub-emitters stay quiet.
- **Gizmos.** A selected system draws its emission shape as lines: the cone's base and spread, the sphere, hemisphere and circle, the edge, the box, a cross for a point.
- **Handles.** In the Handles tool, T, handles edit the cone's radius and angle, the radius of a sphere, hemisphere, circle or edge, and the box's size. One drag is one undo step.

## From code

```odin
import "moonhug:packages/particles"

_, ps := engine.transform_get_comp(fx, particles.ParticleSystem)
particles.system_play(ps)                         // start, or restart a stopped system
particles.system_pause(ps)                        // freeze everything
particles.system_stop(ps)                         // stop emitting, live particles play out
particles.system_stop(ps, clear_particles = true) // and drop them
particles.system_reset(ps)                        // clear all live state
particles.system_emit_at(ps, {0, 2, 0})           // fire the system's bursts at a world point
```

## Limits

See the [module list](../Roadmap.md#modules) for what each module covers.

## See also

- [Simulation](../concepts/Simulation.md)
