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
  `TrackAudio`, `TrackParticles`, `TrackAnimation`, `TrackActivation`,
  `TrackMarker`, `TrackControl`. The registry keys on the kind component's
  TypeKey — there is no `kind` string anywhere. The node's NAME is the track
  name; sibling order is track order.
- **The kind component owns the track's target**, with a `ref:` tag that
  drives the picker: `TrackAudio.source \`ref:"AudioSource"\``,
  `TrackParticles.system \`ref:"ParticleSystem"\``. A kind that needs no
  target (animation, control) simply has no field, and one wanting two
  targets just adds a second. Targets are authored in the prefab or set per
  instance as prefab overrides — overrides ARE the exposure surface, there
  is no binding table and no exposed-reference table.
- **A clip node** likewise carries `TimelineClip` (`start`, `duration`,
  `ease_in`, `ease_out`, `speed`) plus the kind's clip component holding its
  payload: `ClipAudio.clip \`ext:"mp3,wav,ogg"\``,
  `ClipAnimation.clip \`ext:"anim"\``, and empty markers for kinds with
  no payload. The node's name is the clip name (markers fire it). Clip order
  derives from start times.

## Evaluation

`director_tracks` materializes the subtree into per-tick views (temp
allocated, strings borrowed from the live components), so track hooks see
the same `Track_View`/`Clip_View` shapes as before. A structural
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

## Clip blending

`track_clip_weight(clips, index, t)` is the shared rule, Unity's model:
**overlap is the blend.** Where two clips on a track overlap, the earlier
ramps out across the overlap while the later ramps in, so dropping a clip on
its neighbour's tail crossfades with nothing to author — and the pair sums to
1 throughout, so there is no dip or double. Explicit `ease_in`/`ease_out`
still apply at boundaries with no neighbour, and the wider ramp wins where
both exist.

The blend is DERIVED from the spans, never stored, so it cannot disagree with
where the clips sit (moving a clip re-derives it). The canvas draws each
clip's weight curve, which reads as an X across an overlap because both
clips plot the same derived numbers.

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
- `marker`: clips are INSTANTS (`Track_Desc.instant` — the window creates
  them with zero duration), firing `timeline_marker_hook` on crossing rather
  than covering. Never fires from the editor preview, since the hook is game
  code (Unity does not fire signals in preview either).
- `control`: each clip plays a NESTED TIMELINE — the clip node's child
  subtree holding its own director (typically a nested timeline prefab
  instance). Inside the span the child evaluates at the clip-local time with
  the parent's mode; outside it rests at 0.
- `tween`: a clip's span drives its tweens' `evaluate(t)` — pose as a pure
  function of the playhead, so the same tween is exact under Play, scrubbing
  and the edit-mode preview. In Scrub/Preview the timeline owns the pose
  (before the span shows t=0, after it t=1); in Play the game owns objects
  outside spans (the clip evaluates inside and lands on t=1 once on the way
  out). To-style tweens capture their start pose on first evaluation and
  refresh per their capture mode — `.Play` (default) once per play session,
  surviving loop wraps so a loop replays the same motion, `.Enter` on every
  span entry so each pass continues from the current pose. Preview end
  restores the authored pose via evaluate(0) and clears every capture. See
  "Tweens" below.
- `script`: a clip WRAPS SCRIPTS. Each script on the clip gets its optional
  lifecycle procs — enter when playback crosses into the span, tick every
  tick inside it, exit when it leaves (a zero-duration clip fires enter and
  exit together, once). Play mode only — scripts are side effects, and
  posing the timeline must not perform them. See "Scripts" below.

Feature-package kinds:
- `particles`: a clip span plays the bound ParticleSystem, leaving it stops
  the system and CLEARS live particles — the span is the effect's existence,
  so play shows what scrubbing to the same playhead shows. Scrubbing replays
  deterministically — reset + fixed-step advance to the clip-local time,
  exact with a `random_seed`. Author track-driven systems with
  `manual_start`.
- `audio`: crossing a clip's start plays the bound AudioSource (the clip's
  asset replaces the source's clip when set), leaving every span stops it.
  Scrub is silent, preview-play sounds. Author track-driven sources with
  `play_on_awake` off.
- `animation`: drives an ANIMATION COMPONENT (Unity's model — the timeline
  takes over the Animator). `TrackAnimation.target` names which one; unset,
  it finds one on the director, and poses the director's transform directly
  when there is none. The driven component's own playback STANDS DOWN
  (`Animation.timeline_driven`) so the two never write the same transforms
  in one frame, and the track hands it back on preview end or retarget.
  Internally a mixer with one clip node per timeline clip, weights from
  track_clip_weight, source clips shorter than their timeline clip wrapping
  by their own mode. Clips may carry PROPERTY channels
  (docs/PlayableGraph.md).

## Scripts

A script is a `@(typ_guid)` struct plus whichever lifecycle procs it
implements — `enter_<Name>`, `tick_<Name>`, `exit_<Name>`, all optional, and
a `destroy_<Name>` when it owns heap. `ScriptUnion`
(`sequencer/script_union.odin`) names every variant and dispatches each
phase with an exhaustive switch — a variant without its cases is a compile
error, not a clip that silently does nothing.

The layering keeps variants BELOW the union, so first-party and plugin
scripts are structurally identical:

- `sequencer/core` — the vocabulary floor: `Script_Ctx`. Variant packages
  import this, never the sequencer.
- `sequencer/scripts` — the built-ins: `ScriptSetActive` (the target is
  active for the span: enter sets `active`, exit sets it back) and
  `ScriptLog` (enter/tick/exit messages to the log, empty skips the phase —
  the "did my timeline get here" probe).
- `sequencer/gen/script_gen.odin` — GENERATES `script_union_generated.odin`
  (the union, the three dispatch switches, the serialization registration).
  It finds variants by the embedded `Clip_Script` base and probes each
  lifecycle proc by name, so a variant missing a phase gets an empty case.

Persistence is guid-keyed (`engine/serialization` union marshalers): union
tags are positional and shift when a variant is added, so the wire format
carries the variant's type guid instead. `Ref_Local` fields inside a variant
rebind on load like any component field — the resolve walk descends into
unions.

Both unions are `#no_nil` with an inert `TweenNone` / `ScriptNone` sorted
FIRST, so the zero value — what a freshly added list element holds before a
variant is picked — does nothing and still marshals as a guid-tagged object.
A nilable union writes bare `null`, which the marshalers do not read back:
the whole owning component then fails to parse and the loader preserves it
verbatim as an unknown component, so the object shows "Missing Component"
and its list disappears. The zero variant also needs its own `@(typ_guid)` —
guid-keyed marshaling panics on a type without one, which is why the shared
base cannot serve as the zero value.

## Tweens

A clip tween is a `@(typ_guid)` struct embedding `core.Clip_Tween` plus one
`evaluate_<Name>(self, t, ctx)` proc — pose as a pure function of
clip-normalized t in [0..1]. `TweenUnion` (`sequencer/tween_union.odin`)
names every variant and dispatches, hand-written today in the same
generated-artifact shape as ScriptUnion.

Adding a variant is the plugin contract, first-party and third-party alike:
ship a package importing `moonhug:packages/sequencer/core`, declare a
`@(typ_guid)` struct embedding the base, write the procs IN THE SAME FILE
(prebuild is syntax-only — `FileHasProc` is file-scoped and the base is
matched by written name), and run prebuild. `TweenFadeTo` in
`packages/sprites` is the live proof: it poses a SpriteRenderer, so it lives
in sprites, and it reaches `TweenUnion` without the sequencer importing
sprites or naming the type.

Naming: abstract first, concrete later — `Tween<Aspect><Space><Detail>`:
`TweenMoveLocalFromTo` (explicit pair, fully stateless), `TweenMoveLocalTo`,
`TweenScaleLocalTo`, `TweenRotateLocalTo` (captured start). Names must not
collide with `packages/tween`'s node types — the @(typ_guid) name space is
global.

- `sequencer/core` — the floor: `Tween_Ctx`, the `Clip_Tween` base
  (`captured`). Variant packages import this, never the sequencer.
- `sequencer/tweens` — the built-in variants. A variant that poses a
  package-owned component lives in THAT package (`TweenFadeTo` belongs to
  sprites — color is SpriteRenderer's) and joins the union once the
  generator owns the import list.

The visible difference between the modes at a loop's seam is AUTHORITY, not
a bug: in edit mode the timeline owns the pose everywhere, so the object
shows the start pose from the wrap onward (the reset reads as "at timeline
start"); in Play the game owns objects outside spans, so the object holds
the previous pass's end pose until the clip begins, then the tween takes
over (the reset reads as "at clip start"). Both follow from the same rule.

Play sessions: `PlayableDirector.play_id` increments at every session start
(`director_play`, the auto-start, a control span entering in Play — a nested
director never sees director_play, its parent's span IS its play), which is
how `.Play` captures know a new performance began.

This vocabulary is deliberately SEPARATE from `packages/tween` (the
self-ticking graph tweens): both stay untouched by each other, and the union
+ dispatch is the seam if they unify later. Composites do not exist here —
the timeline is the container (a clip holds parallel tweens, consecutive
clips are a sequence).

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

  Two things make the transition land on ONE frame rather than several.
  Play is deferred a frame (`sim.request_start`) so a preview's pending
  restore renders before the scene is captured. And the director REWINDS
  when the preview ends for play: `preview_end` leaves stateful tracks reset
  (particles clear their systems), so resuming mid-timeline would restart
  those effects from empty while instant tracks snap into place — which
  reads as tracks starting on different frames. Waiting MORE frames makes
  that worse, not better; starting from 0 is what syncs them.
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
