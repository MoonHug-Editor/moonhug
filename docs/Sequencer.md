# Sequencer
---

Unity's Timeline: a Timeline asset holds tracks of clips on a shared time
axis, a PlayableDirector component plays it on scene objects.

```
packages/sequencer/                ← knows only the engine
  timeline.odin                    ← Timeline asset + Track_Desc registry
  component_PlayableDirector.odin  ← the player component
  director.odin                    ← per-track build/tick/teardown
  editor/sequencer_editor.odin     ← director inspector (Timeline picker)

packages/animation/track_animation.odin  ← "animation" track (owns its graph)
packages/audio/track_audio.odin          ← "audio" track
packages/particles/track_particles.odin  ← "particles" track
packages/sequencer/editor/view_sequencer.odin ← the window
```

Every track kind — animation included — comes from the registry, so the
sequencer package imports no feature package and each feature package's only
sequencer dependency is its one track file.
---

## Timeline asset

`.timeline` (JSON, guid asset): `duration` (0 = computed from the last clip
end) + `tracks[]`. A track is a registry `kind`, a name, a mute flag and
`clips[{start, duration, ease_in, ease_out, speed, asset, name}]`. The asset
owns STRUCTURE only — scene identity lives on the director.

## PlayableDirector

Component fields: `timeline` (a PPtr — a timeline can later live embedded in
another asset as a sub-asset), `wrap` (Once/Loop), `speed` (0 runs at 1),
`manual_start` (inverse of Unity's play-on-awake, zero-neutral), `bindings`
(`[{track, target: Ref_Local}]` — which scene object each track drives).

Playback: `director_play/pause/stop`, ticked on `@(update)`. Evaluation is a
pure function of director time, so scrubbing is `director_set_time` — the
sequencer window's preview and a future Control Track ride the same path.

## Tracks

Kinds register with `track_register`. A `Track_Desc` supplies `binding_type`
(what the track binds — drives the window's picker) and four hooks: `build`
(once per director+track, returns the kind's own state), `destroy`, `tick`,
and `preview_end` (quiet whatever the track drove when the editor's preview
stops). Hooks receive a `Track_Ctx`: the track, its binding, the director's
owner, the kind's state, the frame's time window (`track_crossed` is the
wrap-aware crossing test), and a `scrub` flag — stateful tracks reset on
scrubs instead of firing crossings.

`animation` (packages/animation/track_animation.odin) keeps its playable
graph in the track state: a mixer with one clip node per timeline clip,
weights from the ease ramps (overlaps crossfade through mixer
normalization), source clips shorter than their timeline clip wrap by their
own wrap mode. Channel paths resolve under the director's owner transform,
so the track binds nothing. Clips may carry PROPERTY channels — any POD
component field by (component guid, dotted field path), see
docs/PlayableGraph.md "Property channels" — so animating a field needs no
new track kind.

Built-in kinds (engine vocabulary, so they ship with the package):
`activation` (the bound transform is active while any clip covers the time)
and `marker` (zero-duration clips fire `timeline_marker_hook` on crossing).

Feature-package kinds:
- `particles`: a clip span plays
  the bound ParticleSystem, leaving it stops it (particles play out).
  Scrubbing replays deterministically — reset + fixed-step advance to the
  clip-local time, exact with a `random_seed`. Author track-driven systems
  with `manual_start`.
- `audio`: crossing a clip's start plays
  the bound AudioSource (the clip's asset replaces the source's clip when
  set), leaving every span stops it, scrubbing is silent. Author
  track-driven sources with `play_on_awake` off.

## Sequencer window

`packages/sequencer/editor/view_sequencer.odin` (Window/Sequencer), laid out
after ImGuizmo's ImSequencer — it lives in the package, reading the
selection through `engine.inspector_active_selection()` and bracketing its
preview through the `editor/preview` hooks (docs/Plugins.md). Targets the selection like the Animation window: the active
transform or its nearest ancestor with a PlayableDirector.

- Toolbar: Preview toggle, rewind, Play/Pause, time / duration, Save, Add
  Track (registry kinds + animation).
Three resizable panes — legend | canvas | inspector — with draggable
splitters between them (both sides keep a minimum width).

The binding picker runs OUTSIDE the inspector, so the window pushes the
director as the inspector owner (`undo.push_component_owner`) around it —
that owner is what `ref_local_owner_root_scene` resolves the target's scene
from, and a picked target with no scene records no `local_id`, leaving a
binding that dies at the next scene reload (Play/Stop).

- Legend column per track: mute, kind, the BINDING picker (filtered by the
  track's `binding_type`, edits the director with a diffing undo session),
  add-clip-at-playhead, remove.
- Canvas: seconds ruler (dragging scrubs), colored clip blocks per track —
  body drags move, edge grips resize (0.1s snap), ease ramps draw as corner
  lines, wheel zooms, the scrollbar pans. Double-click empty row space adds
  a clip there, right-click offers it from a menu, clicking empty space
  deselects. Right-click a clip for Duplicate/Delete, Delete/Backspace
  removes the selection. Track rows right-click for
  Add Clip at Playhead / Rename / Remove Track.
- Inspector pane: the selection's properties stacked one per row — the
  track's name/kind/mute/clip count, then the clip's name (what markers
  fire), start, duration, ease in/out, speed, payload asset (ext-filtered
  per kind), and Duplicate/Delete buttons.
- Edits target the timeline's asset document with whole-document undo
  sessions, sync into the runtime cache (`timeline_preview`, which rebuilds
  playing directors), and Save writes the file.
- Preview: `sequencer_preview_apply/restore` are registered as an
  `editor/preview` hook pair, bracketing the scene/game render like the
  animation scrub preview — poses restore through the
  director's binding defaults, activation flips are captured and restored per
  frame, particles reset and audio stops when the preview ends.

## Sample

`packages/animation/samples/timeline_sample` (installed as the
`packages/timeline_sample` symlink) ships `timeline_demo.scene` — a
manual-start fireworks rocket (Death sub emitter into spinning star sparks,
comet trails, seeded) driven by `fireworks.timeline`'s particles control
track through a PlayableDirector on the root. Open the scene, select
TimelineDemo, and scrub in the Sequencer window.

## Playables additions

Node `speed` scales local time at evaluation (`playable_node_time`).
`playable_clip_length` and `playable_node_done` let drivers poll duration
and completion — evaluation stays pure, no callbacks. `Playable_Output`
bundles a graph + binding with init/destroy/tick (evaluate, apply pose, fire
scripts after the apply), so owners outside `component_Animation` don't
duplicate the plumbing.
