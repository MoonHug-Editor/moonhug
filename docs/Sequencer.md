# Sequencer
---

Unity's Timeline, on one structural decision Unity did not make: **a timeline
is a prefab**. There is no timeline document format — a timeline is a
transform subtree whose root carries a PlayableDirector, with TRACK NODES as
children and CLIP NODES under them. Everything the prefab system does is
therefore a timeline feature:

| Concept            | Mechanism                                        |
|--------------------|--------------------------------------------------|
| Timeline asset     | a prefab (.scene) whose root has a director      |
| Reuse in a scene   | prefab instance                                  |
| Per-instance edits | prefab overrides (targets, times — anything)     |
| Timeline variant   | prefab variant                                   |
| Nested timeline    | nested prefab under a control clip               |
| Embedded timeline  | plain scene content (guid-less, local ids)       |
| Clip identity      | local ids — undo, overrides, multiedit all apply |
| Track kind         | a component — the registry keys on its TypeKey    |

```
packages/sequencer/                 ← knows only the engine
  timeline.odin                     ← view structs + Track_Desc registry + builtins
  component_PlayableDirector.odin   ← playback state + duration
  component_TimelineTrack.odin      ← TimelineTrack, TimelineClip
  director.odin                     ← subtree walk, evaluation, modes
  editor/view_sequencer.odin        ← the window

packages/animation/track_animation.odin  ← "animation" track (owns its graph)
packages/audio/track_audio.odin          ← "audio" track
packages/particles/track_particles.odin  ← "particles" track
```
---

## Structure

- **PlayableDirector** (root node): `wrap` (Once/Loop), `speed` (0 runs at 1),
  `manual_start` (inverse of Unity's play-on-awake), `duration` (0 = last
  clip end). Zero-neutral throughout.
- **A track node** carries TWO components: `TimelineTrack` (`muted` — what
  every track has) and its **kind component**, which IS the discriminator:
  `AudioTrack`, `ParticlesTrack`, `AnimationTrack`, `ActivationTrack`,
  `MarkerTrack`, `ControlTrack`. The registry keys on the kind component's
  TypeKey — there is no `kind` string anywhere. The node's NAME is the track
  name; sibling order is track order.
- **The kind component owns the track's target**, with a `ref:` tag that
  drives the picker: `AudioTrack.source \`ref:"AudioSource"\``,
  `ParticlesTrack.system \`ref:"ParticleSystem"\``. A kind that needs no
  target (animation, control) simply has no field, and one wanting two
  targets just adds a second. Targets are authored in the prefab or set per
  instance as prefab overrides — overrides ARE the exposure surface, there
  is no binding table and no exposed-reference table.
- **A clip node** likewise carries `TimelineClip` (`start`, `duration`,
  `ease_in`, `ease_out`, `speed`) plus the kind's clip component holding its
  payload: `AudioClipRef.clip \`ext:"mp3,wav,ogg"\``,
  `AnimationClipRef.clip \`ext:"anim"\``, and empty markers for kinds with
  no payload. The node's name is the clip name (markers fire it). Clip order
  derives from start times.

## Evaluation

`director_tracks` materializes the subtree into per-tick views (temp
allocated, strings borrowed from the live components), so track hooks see
the same `Timeline_Track`/`Timeline_Clip` shapes as before. A structural
FINGERPRINT (node handles + kinds + clip assets) rebuilds track state when
the tree changes — live edits need no invalidation calls, and field edits
(times, targets) apply on the next evaluation because the components ARE the
data.

Playback: `director_play/pause/stop`, ticked on `@(update)`. Evaluation is a
pure function of director time: `director_set_time` scrubs,
`director_preview_step` is the editor preview's Play advance, and
`director_evaluate_at(d, time, mode)` is the raw form the control track
forwards through. A director nested under a control clip never self-ticks —
the parent timeline owns its time.

## Tracks

Kinds register with `track_register`. A `Track_Desc` supplies `track_key`
and `clip_key` (the kind's two components), a `label` for menus, and four
hooks: `build` (once per
director+track, returns the kind's own state), `destroy`, `tick`, and
`preview_end` (quiet whatever the track drove when the editor's preview
stops). Hooks receive a `Track_Ctx`: the track view (whose `node` is where
the hook reads its OWN component for targets and options), the director's
owner, the kind's state, the frame's time window (`track_crossed`
is the wrap-aware crossing test), and the evaluation `mode`:

- `Play` — the runtime. Crossings fire, side effects are real.
- `Scrub` — time jumped. Stateful tracks reset and replay deterministically;
  nothing sounds.
- `Preview_Play` — the editor preview auto-advances. Crossings are real and
  audio plays live (Unity's Timeline preview), particles keep their replay,
  marker hooks stay silent.

Built-in kinds:
- `activation`: the target is active while any clip covers the time. Outside
  Play mode the tick captures the pre-tick state and `preview_end` restores
  it — authored-inactive objects return to inactive.
- `marker`: zero-duration clips fire `timeline_marker_hook` on crossing,
  never from the editor.
- `control`: each clip plays a NESTED TIMELINE — the clip node's child
  subtree holding its own director (typically a nested timeline prefab
  instance). Inside the span the child evaluates at the clip-local time with
  the parent's mode; outside it rests at 0.

Feature-package kinds:
- `particles`: a clip span plays the bound ParticleSystem, leaving it stops
  it. Scrubbing replays deterministically — reset + fixed-step advance to
  the clip-local time, exact with a `random_seed`. Author track-driven
  systems with `manual_start`.
- `audio`: crossing a clip's start plays the bound AudioSource (the clip's
  asset replaces the source's clip when set), leaving every span stops it.
  Scrub is silent, preview-play sounds. Author track-driven sources with
  `play_on_awake` off.
- `animation`: a mixer with one clip node per timeline clip, weights from
  the ease ramps (overlaps crossfade through mixer normalization), source
  clips shorter than their timeline clip wrap by their own mode. Channel
  paths resolve under the director's owner, so the track needs no target.
  Clips may carry PROPERTY channels (docs/PlayableGraph.md).

## Sequencer window

`packages/sequencer/editor/view_sequencer.odin` (Window/Sequencer), laid out
after ImGuizmo's ImSequencer. Targets the selection like the Animation
window: the active transform or its nearest ancestor with a PlayableDirector.

Because the timeline is scene content, every edit is an ordinary scene edit:
field edits are component undo sessions, structural edits (add/remove/
duplicate tracks and clips) are node create/delete/duplicate through the
same undo the hierarchy uses, and Save saves the owner's scene. The
hierarchy and inspector work on timeline nodes too — a clip is a selectable,
multieditable component like any other.

- Toolbar: Preview toggle, rewind, Play/Pause, time/duration, Save Scene,
  Add Track (registry kinds).
- Legend per track: mute, name (right-click: add clip / rename / remove),
  add-clip, remove.
- Canvas: seconds ruler (dragging scrubs), colored clip blocks — body drags
  move, edge grips resize (0.1s snap), ease ramps as corner lines, wheel
  zooms. Double-click empty row space adds a clip, right-click menus for
  clip Duplicate/Delete, Delete/Backspace removes the selection.
- Inspector pane: the selected track and clip, one field per row, plus each
  one's KIND component drawn through the inspector's default drawing — the
  `ref:`/`ext:` tags filter their own pickers, so the window contains no
  per-kind knowledge at all.
- Preview: `sequencer_preview_apply/restore` bracket the scene/game render.
  Entering play mode ENDS the preview (an `ExitingEditMode` phase hook, plus
  a guard in apply): play owns the world and the director ticks itself
  there, so a scrub posing it every frame would fight the simulation. The
  preview controls disable while playing; editing stays available.
  Play advances with `director_preview_step` (audio live), a paused or
  dragged playhead is a silent scrub, and the per-frame restore quiets
  everything the moment playing stops.

## Sample

`packages/animation/samples/timeline_sample` (installed as the
`packages/timeline_sample` symlink) ships `timeline_demo.scene` — a
manual-start fireworks rocket (Death sub emitter into spinning star sparks,
comet trails, seeded) with track nodes for particles and audio directly
under the TimelineDemo root. Open the scene, select TimelineDemo, and scrub
in the Sequencer window.

## Playables additions

Node `speed` scales local time at evaluation (`playable_node_time`).
`playable_clip_length` and `playable_node_done` let drivers poll duration
and completion — evaluation stays pure, no callbacks. `Playable_Output`
bundles a graph + binding with init/destroy/tick (evaluate, apply pose, fire
scripts after the apply), so owners outside `component_Animation` don't
duplicate the plumbing.
