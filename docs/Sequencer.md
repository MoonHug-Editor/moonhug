# Sequencer
---

Unity's Timeline: a Timeline asset holds tracks of clips on a shared time
axis, a PlayableDirector component plays it on scene objects.

```
packages/animation/
  timeline.odin                    ← Timeline asset + Track_Desc registry
  component_PlayableDirector.odin  ← the player component
  director.odin                    ← build + tick + scrub
  playable_graph.odin              ← evaluation (Playable_Output owns a graph)
```
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

`animation` is built into the director: per-track mixer under a layer-mixer
root, one clip node per timeline clip, weights from the ease ramps (overlaps
crossfade through mixer normalization), source clips shorter than their
timeline clip wrap by their own wrap mode. Channel paths resolve under the
director's owner transform.

Everything else goes through the Track_Desc registry (`track_register`), so
packages add track kinds without this package importing them. A registered
track's `tick` gets a `Track_Ctx`: the track, its binding, the frame's time
window (`track_crossed` is the wrap-aware crossing test), and a `scrub` flag
— stateful tracks reset on scrubs instead of firing crossings.

Built-in registry tracks: `activation` (the bound transform is active while
any clip covers the time) and `marker` (zero-duration clips fire
`timeline_marker_hook` on crossing).

Package tracks — each package's single animation-package dependency is its
track file, the sequencer imports neither:
- `particles` (packages/particles/track_particles.odin): a clip span plays
  the bound ParticleSystem, leaving it stops it (particles play out).
  Scrubbing replays deterministically — reset + fixed-step advance to the
  clip-local time, exact with a `random_seed`. Author track-driven systems
  with `manual_start`.
- `audio` (packages/audio/track_audio.odin): crossing a clip's start plays
  the bound AudioSource (the clip's asset replaces the source's clip when
  set), leaving every span stops it, scrubbing is silent. Author
  track-driven sources with `play_on_awake` off.

## Sequencer window

`editor/view_sequencer.odin` (Window/Sequencer), laid out after ImGuizmo's
ImSequencer. Targets the selection like the Animation window: the active
transform or its nearest ancestor with a PlayableDirector.

- Toolbar: Preview toggle, rewind, Play/Pause, time / duration, Save, Add
  Track (registry kinds + animation).
- Legend column per track: mute, kind, the BINDING picker (filtered by the
  track's `binding_type`, edits the director with a diffing undo session),
  add-clip-at-playhead, remove.
- Canvas: seconds ruler (dragging scrubs), colored clip blocks per track —
  body drags move, edge grips resize (0.1s snap), ease ramps draw as corner
  lines, wheel zooms, the scrollbar pans. A selected clip edits start /
  duration / ease in / ease out / speed / payload asset (ext-filtered per
  kind) / delete in the strip below.
- Edits target the timeline's asset document with whole-document undo
  sessions, sync into the runtime cache (`timeline_preview`, which rebuilds
  playing directors), and Save writes the file.
- Preview: `sequencer_preview_apply/restore` bracket the scene/game render in
  main.odin like the animation scrub preview — poses restore through the
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
