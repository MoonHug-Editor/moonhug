# ParticleSystem
---

CPU particles as a plugin package. The component holds authored settings, the
sim advances every frame, rendering goes through the renderer seam.

```
packages/particles/
  component_ParticleSystem.odin  ← component + Burst struct
  particles.odin                 ← sim (@(update)) + render collector
  editor/particles_editor.odin   ← inspector wrapper (module groups)
  samples/particles_sample/      ← showcase scene (installed as symlink)

engine/curve.odin                ← Curve + Gradient (shared authored types)
editor/inspector/
  property_drawer_curve.odin     ← curve row + popup editor
  property_drawer_gradient.odin  ← gradient row + popup editor
```
---

## Simulation

`particles_tick` runs on `@(update)` and calls `system_tick` per enabled
system. `system_tick` is public so tests drive systems headless.

Each advance:
- ages particles, removes dead ones
- applies gravity (a world force, rotated into the emitter frame for
  local-space sims), limit-velocity dampening, velocity-over-lifetime offsets
- integrates position and billboard rotation
- emits from rate over time, rate over distance (emitter movement), and
  bursts (cycle-local trigger times crossed this tick, looping wraps)

`simulation_speed` scales the advance. `prewarm` runs one full cycle in
substeps on a looping system's first tick. `start_delay` holds emission back.

## Modules and fields

**Main**: `duration`, `looping`, `prewarm`, `start_delay`, `lifetime_min/max`,
`speed_min/max`, `size_min/max`, `rotation_min/max` (start roll, degrees),
`flip_rotation` (0..1 fraction spinning the other way), `color_a/b`,
`gravity_modifier`, `sim_space` (Local follows the emitter, World leaves
particles behind), `simulation_speed`, `max_particles`.

**Emission**: `rate` (per second), `rate_over_distance` (per world unit
moved), `bursts` — each burst is `{time, count_min/max, cycles, interval,
probability}`.

**Shape** (emits along local +Z): Cone (`shape_radius` base + `shape_angle`
spread), Sphere, Hemisphere (+Z half), Circle (XY disc, radial direction),
Edge (X line of half-length `shape_radius`, direction +Z), Box (`shape_box`
volume, direction +Z), Point. `randomize_direction` and `spherize_direction`
(0..1) blend the direction toward random / outward-from-center.

**Velocity over lifetime**: `velocity_x/y/z` curves add velocity in the
emitter frame, evaluated at life/lifetime.

**Limit velocity over lifetime**: speed above `limit_speed` decays toward it
by `limit_dampen` (0..1, per frame at 60 Hz, frame-rate normalized).

**Rotation over lifetime**: `angular_velocity_min/max` in degrees per second.

**Color / Size over lifetime**: `color_over_life` (Gradient) multiplies the
start color, `size_over_life` (Curve) scales the start size.

**Renderer**: `sprite` (PPtr — texture guid + optional slice id), `material`,
`sorting_layer`, `order_in_layer`.

## Unity module coverage

| Unity module | MoonHug |
|---|---|
| Main | yes — no 3D size/rotation, delta time, scaling mode, play on awake, emitter velocity, random seeds, stop action, culling mode, ring buffer |
| Emission | yes |
| Shape | partial — Cone, Sphere, Hemisphere, Circle, Edge, Box, Point; no mesh/sprite shapes, arc, radius thickness, emission texture |
| Velocity over Lifetime | yes — linear x/y/z; no orbital, offset, speed modifier |
| Limit Velocity over Lifetime | yes — speed + dampen; no per-axis limit, no drag |
| Inherit Velocity | no |
| Lifetime by Emitter Speed | no |
| Force over Lifetime | no |
| Color over Lifetime | yes |
| Color by Speed | no |
| Size over Lifetime | yes |
| Size by Speed | no |
| Rotation over Lifetime | yes — angular velocity min/max |
| Rotation by Speed | no |
| External Forces | no |
| Noise | no |
| Collision | no |
| Triggers | no |
| Sub Emitters | no |
| Texture Sheet Animation | no |
| Lights | no |
| Trails | no |
| Custom Data | no |
| Renderer | partial — billboards only (sprite, material, sorting); no stretched/mesh render modes |

## Off-state conventions

Fields absent from a scene file load as zero, so zero means "off" for every
setting: empty curves and gradients disable their module (`curve_eval` empty
value, `gradient_eval` white), `limit_speed` 0 disables limiting, angular
velocity 0 disables rotation. The one exception is `simulation_speed`, where
0 runs at 1. The inspector's module checkboxes read and write this state
directly — enabling seeds default values, disabling clears them. There are no
separate enabled flags on the component.

## Rendering

The collector emits one billboarded `Draw_Quad` per particle: camera right/up
come from the view matrix rows, the particle's roll rotates that basis. Sliced
sprites resolve UVs through `texture_sprite_rect`. Sort keys use
`engine.sort_key_word(layer, order, depth, seq)`, so particles interleave with
sprites in the shared transparent pass.

## Inspector

`particles_editor.odin` registers a full replacement wrapper shaped like
Unity's inspector: main fields flat, then collapsing module groups with
enable checkboxes. Every field runs through the inspector's row machinery
(`field_edit_row`, the enum protocol), so undo, multiedit peers and prefab
overrides behave like generic rows. Burst edits and module toggles bracket
with `structural_edit_begin/end`. Bursts don't propagate to multiedit peers.

## Sample

`packages/particles/samples/particles_sample` ships
`particles_samples.scene` — Fountain, Burst, Smoke, Snow exhibits — with its
own texture and authored metas.
