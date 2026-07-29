# PlayableGraph

> Implemented through the milestone (sequence steps 1-4): the graph core
> (engine/playable_graph.odin), the Animation component driver
> (engine/component_Animation.odin), and tests
> (tests/playable_graph_tests.odin). Later sequence steps are design.

The animation evaluation layer. A PlayableGraph is a graph of nodes where
leaves sample sources (animation clips, audio clips, script callbacks),
interior nodes blend their inputs by weight, and typed outputs deliver the
result to a bound target. Evaluation is a pull from the outputs at an explicit
time, with no side effects until the output writes.

The model is Unity's Playables. The API surface is not — it is idiomatic to
this codebase: pooled structs addressed by handle, a union for the closed set
of node kinds, parallel arrays. Editor UX built on top (Animation window,
Timeline) follows Unity literally, the runtime underneath does not have to.

## Why a graph

Three consumers, one evaluator:

- **Edit-mode scrubbing** — the Animation window's playhead is
  "evaluate this graph at time t while stopped". Same code path as play mode,
  no special case around the runtime.
- **Blending** — a cross-fade is a two-input mixer with animated weights.
  Impossible in the current runtime, where `animation_clip_apply` writes each
  sampled channel directly into the transform as it goes.
- **Timeline and the Mecanim replacement** — both become *drivers* of a graph
  (see Drivers below), not second animation runtimes.

## The invariant everything depends on

**The graph is a pure evaluator** — evaluation is a function with no memory:
`evaluate(graph, time) -> pose`. Same graph, same time, same result, in any
call order. Nodes may compute from their own local time and their inputs, but
never mutate graph structure or sibling state, and hold no state that
survives between evaluations.

The current runtime mixes the two jobs this separates: `animation_tick` both
ADVANCES time (`a.time += dt * a.speed` — state, remembers last frame) and
SAMPLES the clip at that time (math, no memory). The component keeps the
remembering (time, what is fading, what is queued), the graph keeps only the
math.

**Mutating the graph BETWEEN evaluations is normal — that is what drivers
do.** `cross_fade` adds a clip node, a finished fade-out removes one. Unity
does the same (Animancer creates a ClipPlayable per Play, Mecanim splices
transition structures in and out). Every frame is mutate-then-evaluate:
drivers restructure and reweight first, then evaluation walks the resulting
structure read-only. The invariant only forbids the pathological case — a
NODE rewiring or reweighting the graph WHILE being evaluated — because that
is what breaks "evaluate twice at the same time, get the same pose".

This purity is what makes scrubbing trustworthy, Timeline preview possible,
and the evaluator testable headlessly. Anything stateful or history-dependent
(a state machine deciding transitions, gameplay code reacting to events) lives
in a driver above the graph, never inside it.

Pure helper nodes are allowed: a crossfade node that derives its two input
weights from its own local time is fine. A node that rewires connections or
writes a sibling's weight is not.

## Layering

```
gameplay code — animation logic as ordinary code, calling the component API
  │
drivers — own state and decisions, write node times/weights
  ├─ Animation component       play / cross_fade / queue — owns the playback
  │                            bookkeeping (v1: one clip, then grows)
  └─ Timeline                  deterministic driver: playhead maps to node
                               times/weights (future)
─────────────────────────────────────────────────────────────────
graph — pure: nodes, time/weight propagation, typed outputs
```

Precedent: everything in this space is already a driver. Unity's Mecanim is an
AnimatorController asset interpreted by the Animator, which drives an internal
playable graph. Timeline is a PlayableDirector driving a graph built from the
timeline asset. Animancer is a thin code-level driver over raw playables.

**There is no Controller / state-machine layer.** Mecanim's
triggers/parameters are not a feature to reproduce — they are the tax of
making the state machine a data asset: data cannot call functions, so Unity
invented a string-keyed mailbox for code to poke it. With animation logic in
gameplay code, the interface is calling a proc. A state-machine ASSET remains
possible as an optional future client of the component API (only if
non-programmer authoring is ever needed) and costs nothing to leave open.

What does NOT dissolve with the Controller is the playback bookkeeping — it
moves into the Animation component (see What Animation becomes): cross-fade
management, interruption, queue/lifecycle. That lump must live somewhere
central or every gameplay file reimplements it badly.

## Core: time and weight propagation

The domain-agnostic spine every node shares:

- A node has **local time**, **speed**, and **duration**. Advancing the
  graph's time advances node local times through the speed multipliers.
  Drivers may also SET local times directly (Timeline does exactly this).
- Each input connection has a **weight** (0..1). Weights are data, written by
  drivers or derived by pure helper nodes, never by evaluation itself.
- One playhead can drive an animation track, an audio track, and a script
  track together because this machinery is shared across domains. This is the
  whole reason Timeline-on-Playables works.

Node kinds are a closed union (precedent: `TweenUnion` in docs/Tweens.md):

- `Clip_Node` — leaf, samples an `AnimationClip` at local time into a pose.
- `Mixer_Node` — blends N input poses by weight.
- `Layer_Mixer_Node` — combines layer poses bottom-up: start from the default
  pose, blend each layer's pose over the running result by the layer's
  weight. A higher layer overrides lower ones wherever it animates a channel.
- `Script_Node` — leaf, invokes callbacks (see Script below).
- `Audio_Clip_Node` — leaf, designed now, lands when audio playback exists
  (see Audio below).

Avatar masks (restricting a layer to a transform subset — legacy Unity's
`AddMixingTransform`) are the first real extension and wait until something
needs them.

## Typed outputs

The graph has outputs of several kinds, each pulling through the same
time/weight structure:

- **Animation output** — pulls poses, writes the final pose once to a bound
  transform subtree.
- **Script output** — invokes callbacks with `(time, weight)`.
- **Audio output** — produces frame-quantized play/stop/volume commands for
  the audio runtime (designed now, unimplemented until playback exists — today
  the engine imports audio files but has no playback: no source component, no
  device, no mixer).

Evaluation is per-output-kind pull, NOT "evaluate returns a pose". Getting
this wrong is the expensive mistake: if the evaluator's result type is a pose,
script and audio get bolted on later as side-channels. The animation pull and
script collection are implemented, audio is the designed-but-unbuilt third.

## The pose buffer (animation output internals)

The structural change to the existing runtime is splitting
**sample → blend → write** with an explicit intermediate. A pose is a set of
`(target, position?, rotation?, scale?)` values per animated transform — each
component optional, because a channel may animate only one of them.

- Clip leaves sample into poses. Mixers blend poses. The output applies the
  final pose to the hierarchy once.
- `animation_clip_apply`'s direct-write behavior is what this replaces.
  Blending needs all candidate values before anything is written.

### Default pose rule

**A partially-weighted or partially-covering blend resolves against the
default pose — values captured at bind time — never against the live
transform.** Blending against live values feeds back frame to frame and
drifts.

Consequences:

- The animation output owns a snapshot of rest values for every bound channel,
  captured when the output binds.
- Clip A animating only `child/position` mixed 50/50 with clip B animating
  only `child/rotation`: position blends A against the default, rotation
  blends B against the default.
- A single clip at weight 0.3 blends 0.3 clip against 0.7 default pose.

This rule leaks into everything (it is most of what makes additive layers and
avatar masks possible later) and is copied from Unity literally. It is the
kind of semantic that is very expensive to change after clips and games depend
on it.

Prior art worth keeping in view: Spine's apply takes a per-call
`MixBlend: setup | first | replace | add` — blend-against-setup-pose is its
default (agreeing with the rule above), and additive arrives as a *blend mode
on an existing connection*, not a new node kind. When additive blending is
needed here, that is the shape to copy: a per-input blend mode on the mixer,
no new union variant. Spine also shows the failure mode this design avoids:
it blends timelines directly into the skeleton in track order instead of
using pose buffers, and its `holdPrevious`/mix-era machinery exists to patch
the ordering artifacts that come with that. The pose buffer trades a little
memory for order-independent blending.

### Quaternion blending

Two inputs: slerp (matches `_animation_channel_sample` today). Three or more:
normalized lerp (nlerp) with neighborhood correction (flip a quaternion whose
dot with the accumulator is negative before adding). True multi-way slerp is
not associative and not worth it.

### Binding cache

`_animation_resolve_target` currently walks the hierarchy by name string on
every apply. The graph output binds ONCE: name path → transform handle, cached
in the output, invalidated on hierarchy change (rename, reparent, delete under
the bound root). Rebind on invalidation, report unresolved channels rather
than silently skipping them.

## Script nodes

Odin-shaped: no closures, no GC. A script node is a vtable plus user data:

```odin
Script_Playable :: struct {
    user_data: rawptr,
    on_play:   proc(data: rawptr),
    on_pause:  proc(data: rawptr),
    process:   proc(data: rawptr, time: f32, weight: f32),
}
```

Timeline markers/signals are zero-duration script nodes. Weight is passed
through and the callback decides what it means (Unity does the same).

**Callbacks fire after evaluation, never during it.** The script output
collects `(node, time, weight)` entries while pulling and invokes them only
once every output has finished writing. Spine queues events the same way.
This keeps evaluation pure even though callbacks are free to mutate the world
— a callback can never observe or corrupt a half-evaluated frame.

## Scrub policy per domain

Scrubbing degrades by domain. This is inherent, not a design flaw:

| Domain    | Scrub behavior |
|-----------|----------------|
| Animation | Perfect — evaluation is pure, any time is valid. |
| Script    | Explicit per-node policy, copied from Unity's marker options: fire, skip, or fire-and-rewind when the playhead crosses it during a scrub. |
| Audio     | NON-GOAL. Audio plays only during actual playback. Editor audio scrub is famously bad even in Unity and is not attempted. |

## What Animation becomes

v1: a thin wrapper that builds a one-clip graph on play and drives its time.
Same fields, same inspector, same `play_automatically`, zero behavior change
for existing scenes. **This is the compatibility test for the whole refactor:
if `Animation` cannot be expressed trivially on the graph, the graph is
wrong.**

Then it grows the rest of Unity's legacy Animation API — this is a MUST, not
an extension: `cross_fade(clip, duration)`, queued play
(Unity's `CrossFadeQueued`), stop, and LAYERS (legacy Unity's
`state.layer`). The component owns all playback state: the fade list, the
queue, per-layer states, removal of finished one-shots from its graph.

Layers are AUTHORED on the component: a serialized `layers` list, each entry
holding the clips gameplay plays on it, edited in the inspector like any
array field. The list is declarative — nothing in it starts by itself (only
`clip` + `play_automatically` auto-starts) — and its job is layer
resolution: play/cross_fade called without a layer argument look the clip up
here, so call sites stay `animation_cross_fade(a, clip_guid)`. An explicit
layer argument overrides, and unlisted clips land on layer 0.

**THE MILESTONE: an Animation component with N layers, each holding M clips,
producing a PlayableGraph with working cross-fade and interruption.** That is
legacy Unity Animation's feature set, completed. The graph it builds per
component: one layer mixer at the root, one mixer per layer, one clip node
per playing state as leaves. A Once clip that finishes holds its final pose —
when every state is done the component stops evaluating and freezes, matching
the pre-graph runtime.

**Interruption is smooth by construction, not by snapshot.** Fades are
weight-continuous per state: cross-fading to C mid A→B just retargets — every
state fades to 0 FROM ITS CURRENT WEIGHT while C fades in, so the blended
pose never jumps. Weights on a layer sum to 1 whenever they summed to 1
before the call (each old weight w becomes w * (1-k) as the new state reaches
k), and the first fade-in on an empty layer blends up from the default pose.
This is Unity's legacy weight model rather than Mecanim's transition model —
the transition model is what needs frozen-pose snapshots to avoid pops, and
is why Animancer earns its price and Spine grew `holdPrevious`.

- `animation_tick` stays `@(update)` per-frame (Unity animates in Update, not
  FixedUpdate — docs/FixedTick.md keeps view-side work per-frame).
- The graph stays agnostic about who advances time. That property is what the
  editor scrubber rides on.
- The component owns its graph, pooled like everything else.

The tween system (docs/Tweens.md) stays untouched — procedural, not
clip-based, a different concept.

## Non-goals

- Unity's full Playables generality: per-node PrepareFrame/ProcessFrame
  lifecycles, runtime sub-graph connection surgery, video playables, DSP
  graph integration. That generality is why Unity's API is clunky.
- Editor audio scrubbing (see table above).
- State machines: inside the graph never (purity), as a data asset only if
  non-programmer authoring ever demands it (see Layering). Animation logic is
  ordinary gameplay code.
- Avatar masks in v1 (first real extension, designed-for but not built).
  Layer mixing itself IS v1 — see the milestone in What Animation becomes.

If a node union with a handful of variants covers years of features, that is
success, not under-engineering.

## Graph asset (editable graphs) — future

Graphs are code-built first, and the code API stays first-class forever (a
two-clip crossfade is less friction in code than in any asset). An authored
graph ASSET comes later, once the runtime settles, as a reusable rig — e.g. a
locomotion blend tree used by many characters. The node canvas (below) grown
into an editor is its authoring UI, and the asset loader is just another
client of the same graph-construction API.

The asset is a TEMPLATE, which forces three designs that code-built graphs
never needed — they are the real work, the canvas is the small half:

- **Exposed parameters** — named inputs ("run_weight") that drivers write by
  name/handle instead of poking node indices.
- **Instancing** — asset = shared immutable template, each component owns a
  runtime instance with its own times and weights (Spine's
  SkeletonData/Skeleton split, same pattern as the material cache).
- **Clip slots** — per-instance clip overrides ("this character's walk"), or
  reuse dies and every character needs its own asset.

**Structure-only rule (invariant, same rank as purity):** the asset describes
structure and defaults — nodes, connections, default weights and speeds.
Every dynamic comes from outside writes. No conditions, no transitions, no
"activates when parameter > x" in the data, or Mecanim reassembles itself by
accident.

Wrinkle to design in, not discover: `Script_Playable` holds proc pointers,
which do not serialize. Authored script nodes reference registered names
through a registry (the ext-component registry is the precedent).

## Graph UI (node canvas) — shared infra, not a prerequisite

Several future editors want a node-graph canvas: a PlayableGraph debug
visualizer, the Controller's state graph, ShaderGraph, VfxGraph — possibly
two windows at once with cross-graph links (Controller window pointing into
the PlayableGraph window, drawn via the foreground draw list, which can cross
window bounds within a viewport). That canvas (pan/zoom grid, node chrome
with ports, edge routing, marquee selection, undo integration) should be ONE
shared editor component, built once.

What the canvas is NOT: a shared document model. A shader graph compiles to
shader source, a playable graph evaluates poses — the shared layer is
strictly presentation and interaction. Domains supply node types, port
compatibility rules, and what happens on edit.

Sequencing consequence, stated explicitly because it is tempting to invert:
**nothing in this document waits for the canvas.** The runtime is pure data
with no UI dependency, and the Animation window is a timeline/dopesheet/curve
editor, not a node editor. The canvas's first client is the cheapest one — a
READ-ONLY PlayableGraph visualizer (auto-layout, no editing), Unity's
PlayableGraph Visualizer being the model — which is a fraction of an
authoring editor and can grow into one when the Controller or ShaderGraph
arrives.

## Sequence

Done:

1. This document reaches an accepted state.
2. Engine core (playable_graph.odin): pose types, node pool, evaluator,
   script collection, animation output with binding cache and default-pose
   blending. Headlessly tested (tests/playable_graph_tests.odin) — blend
   semantics, layer stacking, rotation nlerp, script deferral.
3. `Animation` ported onto the graph. Existing scenes behave identically
   (the pre-graph component test passes unchanged).
4. **MILESTONE** — `Animation` has layers, cross-fade, interruption, queue
   (see What Animation becomes): N layers x M clips on a live graph.
5. Editor scrub preview (editor/view_animation.odin): the Animation window
   picks a clip on the selected object's Animation component and scrubs it
   while stopped. Preview is a per-frame apply/restore cycle — refresh the
   binding defaults from the live transforms, evaluate at the scrub time,
   apply the pose for the scene/game render, write the defaults back — so
   the world holds authored values whenever saves, undo or the inspector
   run. Preview cannot leak into files by construction, and there is no
   preview state to revert when it ends.
6. Animation window UI: dopesheet (rows per channel, diamond keys, drag to
   retime, double-click to add a shape-preserving sampled key, right-click
   to delete) and curves (per-component polylines, drag keys in time and
   value, rotation keys renormalize on release), with a selected-key field
   row for exact values. Keyframes edit the clip's ASSET DOCUMENT — the
   session registry the project inspector uses — so every operation is a
   whole-document undo step found by guid, and edits live-preview through
   the engine clip cache (animation_clip_preview, the material_preview
   pattern) that the scrub preview and runtime sample. Save writes the
   document to the .anim file.
7. Node canvas (editor/node_canvas.odin) seeded by the read-only visualizer
   (editor/view_playable_graph.odin, the Playable Graph window). The canvas
   is the shared presentation/interaction layer from Graph UI above:
   pan/zoom grid, node chrome with ports, bezier edges, node dragging and
   selection — no document model, ports render but do not interact yet.
   The visualizer ranks nodes by depth from the root (leaves left, output
   right), keeps dragged positions until the structure changes, and shows
   the most live source available: the component's runtime graph, else the
   scrub-preview graph, else the authored shape the component builds when
   it plays. Edge opacity and labels follow input weights when live.

Next:

8. Later, in whatever order need dictates: audio playback runtime + audio
   output, the graph asset + canvas-as-editor (see Graph asset above),
   Timeline, ShaderGraph/VfxGraph, and a state-machine asset only if
   non-programmer authoring ever demands it.
