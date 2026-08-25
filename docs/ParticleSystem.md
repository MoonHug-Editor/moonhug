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
particles behind), `simulation_speed`, `max_particles`, `random_seed`
(0 draws a fresh seed each reset — auto; any other value replays the exact
same effect after `system_reset`), `manual_start` (the inverse of Unity's
Play On Awake, zero-neutral: true = the system waits for `system_play`).

**Playback control**: `system_play` (starts, or restarts a stopped system),
`system_pause` (freezes everything), `system_stop` (ends emission, live
particles play out — `clear_particles = true` drops them, Unity's
StopEmittingAndClear).

**Emission**: `rate` (per second), `rate_over_distance` (per world unit
moved), `bursts` — each burst is `{time, count_min/max, cycles, interval,
probability}`.

**Shape** (emits along local +Z): Cone (`shape_radius` base + `shape_angle`
spread), Sphere, Hemisphere (+Z half), Circle (XY disc, radial direction),
Edge (X line of half-length `shape_radius`, direction +Z), Box (`shape_box`
volume, direction +Z), Point. `randomize_direction` and `spherize_direction`
(0..1) blend the direction toward random / outward-from-center.

**Velocity over lifetime**: `velocity_x/y/z` curves add velocity in the
emitter frame, evaluated at life/lifetime. `orbital_x/y/z` curves (degrees
per second) rotate particle positions around the emitter's axes.

**Limit velocity over lifetime**: speed above `limit_speed` decays toward it
by `limit_dampen` (0..1, per frame at 60 Hz, frame-rate normalized).

**Force over lifetime**: `force_x/y/z` curves accelerate (add to velocity) in
the emitter frame, evaluated at life/lifetime.

**Lifetime by emitter speed**: `lifetime_by_speed` multiplies a new
particle's lifetime by the curve evaluated at the emitter's speed remapped
from `[*_min, *_max]` to 0..1.

**Rotation over lifetime**: `angular_velocity_min/max` in degrees per second.

**Noise**: deterministic smooth value noise jitters positions —
`noise_strength` (world units per second, 0 = off), `noise_frequency`
(0 behaves as 1), `noise_scroll_speed` (moves the field over time).

**Sub emitters**: `sub_emitters` entries reference another ParticleSystem
(`Ref_Local`) with a trigger (Birth or Death) and a probability. A trigger
fires the target's authored BURSTS once, anchored at the particle's position
— the target authors its per-trigger emission as bursts. A referenced target
never emits on its own timeline (`mark_sub_targets`, Unity's rule) — only
triggers or `system_emit_at` fire it (the preview's Self scope lifts the
rule for isolation testing). Chains and
self-targets are depth-limited. Emission draws on the target's own random
stream, so seeded replay stays deterministic.

**Rotation by speed**: `rotation_by_speed` curve adds angular velocity
(degrees per second), evaluated at the particle's speed remapped from
`[*_min, *_max]` to 0..1.

**Color / Size over lifetime**: `color_over_life` (Gradient) multiplies the
start color, `size_over_life` (Curve) scales the start size.

**Color / Size by speed**: `color_by_speed` (Gradient) and `size_by_speed`
(Curve) multiply like the over-lifetime modules, evaluated at the particle's
speed remapped from `[*_min, *_max]` to 0..1.

**Renderer**: `sprite` (PPtr — texture guid + optional slice id), `material`,
`render_mode` (Billboard, or Stretched — the quad aligns to velocity, length
= size * `stretch_length_scale` + speed * `stretch_speed_scale`, length scale
0 behaves as 1), `sorting_layer`, `order_in_layer`.

## Unity module coverage

| Unity module | MoonHug |
|---|---|
| Main | yes — no 3D size/rotation, delta time, scaling mode, emitter velocity, stop action, culling mode, ring buffer |
| Emission | yes |
| Shape | partial — Cone, Sphere, Hemisphere, Circle, Edge, Box, Point; no mesh/sprite shapes, arc, radius thickness, emission texture |
| Velocity over Lifetime | yes — linear + orbital x/y/z; no offset, speed modifier |
| Limit Velocity over Lifetime | yes — speed + dampen; no per-axis limit, no drag |
| Inherit Velocity | no |
| Lifetime by Emitter Speed | yes |
| Force over Lifetime | yes — x/y/z curves |
| Color over Lifetime | yes |
| Color by Speed | yes |
| Size over Lifetime | yes |
| Size by Speed | yes |
| Rotation over Lifetime | yes — angular velocity min/max |
| Rotation by Speed | yes |
| External Forces | no |
| Noise | yes — strength/frequency/scroll; no octaves, damping, per-axis, quality |
| Collision | no |
| Triggers | no |
| Sub Emitters | partial — Birth + Death triggers fire the target's bursts at the particle; no Collision/Trigger/Manual, no inherit, no attached (following) sub systems |
| Texture Sheet Animation | no |
| Lights | no |
| Trails | no |
| Custom Data | no |
| Renderer | partial — billboard + stretched billboard; no mesh render mode, trails material, pivots |

## Off-state conventions

Fields absent from a scene file load as zero, so zero means "off" for every
setting: empty curves and gradients disable their module (`curve_eval` empty
value, `gradient_eval` white), `limit_speed` 0 disables limiting, angular
velocity 0 disables rotation. Two exceptions: `simulation_speed` 0 runs at
1, `random_seed` 0 means auto (a fresh seed each reset). The inspector's module checkboxes read and write this state
directly — enabling seeds default values, disabling clears them. There are no
separate enabled flags on the component.

## Rendering

The collector emits one billboarded `Draw_Quad` per particle: camera right/up
come from the view matrix rows, the particle's roll rotates that basis. Sliced
sprites resolve UVs through `texture_sprite_rect`. Sort keys use
`engine.sort_key_word(layer, order, depth, seq)`, so particles interleave with
sprites in the shared transparent pass.

## Gizmos

The selected system draws its emission shape as wireframe lines in the scene
view — cone base + spread silhouette, sphere/hemisphere circles, circle,
edge line, box, point cross (`editor/particles_gizmos.odin`, the
`@(on_draw_gizmos_selected)` hook).

## Edit-mode preview

The inspected EFFECT plays in edit mode, like Unity's scene-view particle
preview: the whole ParticleSystem hierarchy from its root ticks every frame
the inspector draws — child systems and sub-emitter targets simulate too,
and selecting a child previews the effect it belongs to. Selecting a
different system restarts the effect, deselecting clears it. The scene
view's Particle Effect overlay shows Play/Pause, Restart, Stop, a scope
dropdown (Root plays the whole effect, Self & Children the inspected
subtree, Self the system alone — in Self scope a sub-emitter target plays
its own timeline and the system's own sub-emitters stay quiet, full
isolation) and the playback time + scoped
particle count. Play/simulate owns playback — the preview
stands down while playing. `system_reset` clears live state for the restart.
The preview renders in every view, game view included — with several scenes
open, every enabled camera renders a pass (camera stacking), so a second
scene's camera shows the preview too.

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
