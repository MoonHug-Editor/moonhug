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

## Playables additions

Node `speed` scales local time at evaluation (`playable_node_time`).
`playable_clip_length` and `playable_node_done` let drivers poll duration
and completion — evaluation stays pure, no callbacks. `Playable_Output`
bundles a graph + binding with init/destroy/tick (evaluate, apply pose, fire
scripts after the apply), so owners outside `component_Animation` don't
duplicate the plumbing.
