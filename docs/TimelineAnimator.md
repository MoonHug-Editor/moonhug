# TimelineAnimator

> Design, except TODO item 1 (the graph's output list), which is implemented
> in packages/animation/playable_graph.odin. The rest builds on the animation
> track (packages/animation/track_animation.odin) and the director
> (packages/sequencer/director.odin).

An animation state machine one abstraction level above clips. A state plays a
whole TIMELINE instead of a single clip, so a state can carry several tracks,
several targets, audio, activation and script markers, and still cross-fade
against another state.

`component_Animation` stays. It covers the case where a timeline is overkill:
one object, a few clips, play and cross-fade. TimelineAnimator is the case
where a state is a small performance rather than a single motion. The simple
component is not finished either — it needs a comparable API and marker
callbacks before it is useful on its own.

This is an engine tool, not a solution to one game's current needs. Breadth
matters more than fitting the shape of whatever is being built today.

## Bindings

**A track's own target is the only binding there is.** An animation track
names the Animation it drives, an audio track the AudioSource, exactly as they
do in a standalone timeline. A TimelineAnimator adds no binding layer of its
own: it reads those targets to size its outputs, and changes only WHERE a
track's subtree hangs — inside the animator's one graph, so several states
blend — never what the track drives.

Two things follow, and both are the prefab system doing the work rather than
this component:

- **A timeline is reusable across characters** by living inside the
  character's prefab. Its tracks target objects in that prefab, and a second
  character is a second instance. Retargeting is a prefab override on a
  track's `target`.
- **A timeline needs no setup to play under an animator.** Author it, point
  its tracks at what they drive, add a state naming it. Nothing else.

The animator's inspector draws every track's binding field under the state
that plays the timeline (`Track_Desc.binding_field`), so all the objects a character
depends on are read and edited in one place. But those rows edit the tracks'
own fields — undo lands on the track component, a prefab override records
against the track — so the same timeline still plays standalone, unchanged.

**A track's kind is its own business.** The animator never names a component
type. An animation track finds an Animation and poses it, an audio track finds
an AudioSource and plays through it, and the animator builds a pose output for
each distinct object its animation tracks drive. A kind in any plugin joins by
naming its binding field on its `Track_Desc` — no import of this package. Only
the name is registered: the field's type and picker tags are read off the
struct, so the row here can never disagree with the track's own inspector.

### Why not keys

The first design routed tracks through named slots: a track said "Body", the
animator mapped "Body" to an object, so one timeline PREFAB could serve several
animators binding different objects. Built, then removed, for three reasons:

- The reuse it enabled was already covered. A timeline lives in the same file
  as its animator (`Ref_Local`), so sharing across characters is the whole
  animator as a prefab — and prefab instances retarget on their own.
- Under an animator a track's own target was ignored, so a self-contained
  timeline did nothing until every track was keyed and every key bound. Two
  free-text strings had to match, and a typo was invisible until runtime.
- What keys alone could do — one animator playing one timeline object into
  different objects across states — nobody needs. Duplicating the timeline
  subtree covers it if it ever comes up.

`ref_tags`, `ref:` lists and `has:` stayed: they are picker features with no
dependence on this component.

## Levels

Each level is a DEFAULT for the level above it. A higher level overrides a
lower one wherever both have a value, and the highest one present wins.

- A track with no `target` drives its director's own object. A `target`
  overrides that.
- An `Animation` playing its own clip is a default. A timeline's animation
  track driving that component overrides it. A TimelineAnimator driving that
  timeline overrides that.

So every level works with nothing above it configured, and anything a level
sets can be replaced from above. `timeline_driven` on `Animation`,
`_director_is_control_driven` for a director inside a control track's clip,
and the parking TimelineAnimator does to a state's director are not three
solutions to one problem — they are this one rule at three places. A driver
added later takes its place in the order rather than inventing its own
handshake.

The same rule decides who owns the playable graph: the highest level present
owns it, and everything below attaches a subtree under a parent handle it is
handed.

## One graph, many outputs

A TimelineAnimator owns ONE playable graph. Every state's timeline contributes
a subtree into that graph, and only the TimelineAnimator writes.

This is the requirement everything else rests on. Weights blend correctly only
inside a single evaluation, because `animation_pose_apply` resolves partial
weight against the BIND-TIME DEFAULT pose. Two timelines that each evaluate and
apply on their own, both at weight 0.5, do not cross-fade — the second write
replaces the first, and the result is one timeline at half strength.

Multiple outputs are the graph's own design (docs/PlayableGraph.md, "Typed
outputs"), not something TimelineAnimator introduces. TimelineAnimator is the
first consumer that needs more than one of them, which is what brings the
implementation up to the spec.

An output varies along two INDEPENDENT axes:

- **Kind** — what it writes. Pose, script callbacks, audio commands. Decided
  by the track that feeds it, never declared on the binding.
- **Object** — the transform it writes to, the one a track targets.

Several outputs of the same kind is the normal case, not an edge one: a
performance that poses three characters has three pose outputs.

One output per distinct object the states' animation tracks drive, read from
the tracks' own targets when the graph is built rather than when a state first
reaches one. Every binding then captures its default pose at the same
deterministic moment, and an output nothing feeds costs one empty pose per
frame. Building outputs as tracks arrive would save that and pay for it with
captures happening at arbitrary times, which is the harder bug.

```odin
Graph_Output :: struct {
	kind:    Output_Kind,
	root:    Playable_Handle,
	target:  engine.Ref_Local,  // the output component
	binding: Animation_Binding, // pose outputs only
}

Playable_Graph :: struct {
	...
	outputs: [dynamic]Graph_Output,
}
```

Evaluation is a pull per output. Node handles stay in one space, so connect,
weight and time are unchanged.

**Disjointness is a per-kind rule.** Two POSE outputs whose bound subtrees
overlap write the same transforms and clobber each other, so that pair is an
error. A pose output and an audio output on the same object write different
things and never conflict. The check runs once when the output set is built,
not per state.

`Playable_Graph.outputs` holds them, `playable_graph_tick` evaluates and
applies each and fires the collected scripts once at the end, and
`playable_graph_evaluate(g, root, binding)` is the pure primitive underneath.
`Playable_Output` remains as the wrapper for a graph with exactly one output,
which is what a driver posing a single target uses.

Script and audio are still not output KINDS — scripts leave evaluation through
an out-param and audio through `Track_Desc.tick`. Straightening that is the
first item under Next.

## Graphs do not nest

`Playable_Graph` is an ARENA, not a graph. It holds the node storage, the free
list and the outputs. The graph itself — the DAG — lives in
`Playable_Node.inputs`, so any handle is a subtree root and any subtree is an
input to another node. A subtree already IS a node, and `playable_connect` is
how one is plugged into another.

Two things do not nest, and neither of them is the graph:

- **The arena.** `Playable_Handle` is an index into `g.nodes`. It is an
  allocator offset, not an identity, so two arenas cannot name each other's
  nodes.
- **An output.** It writes to a binding and terminates. A sink is not
  something another node consumes.

So there is no "combine two graphs" operation and none is planned. Anything
reusable composes by being BUILT INTO the host arena, the way a prefab
instantiates into a scene rather than being referenced live. That is what
`docs/PlayableGraph.md` already specifies for the future graph asset: a shared
immutable template, a per-instance runtime copy, exposed parameters instead of
poked node indices.

## The tree

```
Graph
├── Output (pose, Body)         the object the Body tracks target
│   └── Layer_Mixer
│       ├── Mixer  layer 0
│       │   ├── Mixer  state "Idle"   w = 1 - fade
│       │   │   ├── Mixer  track      (clip ease weights)
│       │   │   └── Mixer  track
│       │   └── Mixer  state "Run"    w = fade
│       └── Mixer  layer 1            w = layer weight
└── Output (pose, Face)
    └── Layer_Mixer
        └── ...
(audio tracks play through their own AudioSource and enter no output — see
docs/PlayableGraph.md, "Typed outputs")
```

## Weight

A state has ONE weight. The cross-fade moves it, and it is written to one
mixer input per output the state touches.

Nothing multiplies weights by hand. A mixer input weight propagates down the
whole subtree during evaluation, so setting the state's input weight scales
every track and every clip under it:

```odin
playable_set_input_weight(&g, layer_mixer, state_node, w)
```

**Every playable handles its own weight.** The graph delivers the number, the
node decides what it means. `Playable_Script.process` already receives it, so
a track that produces side effects rather than a pose — audio, activation,
markers — builds a script node and reads the weight there. There is no path
out of the manager that skips it.

Cross-fade is weight-continuous, the same rule `component_Animation` uses:
fading to C in the middle of an A to B fade retargets A and B toward 0 from
their CURRENT weights while C rises. No snapshots, and weights that summed to
1 still sum to 1.

## Data

TimelineAnimator is a plain component. Its layers and states are its own
serialized fields, not a separate asset — sharing a state set between objects
is what putting the component in a PREFAB already does, the same way a timeline
is a prefab rather than a bespoke asset type.

```odin
@(component={menu="Animation/TimelineAnimator"})
TimelineAnimator :: struct {
	using base: engine.CompData,
	speed:      f32,
	layers:     [dynamic]Animator_Layer,

	// runtime, not serialized
	graph:      Playable_Graph,
	rt:         [dynamic]Layer_Runtime,
	out_object: [dynamic]engine.Transform_Handle, // parallel to graph.outputs
}

Animator_Layer :: struct {
	name:          string,
	default_state: string,
	weight:        f32,
	states:        [dynamic]Timeline_State,
}

Timeline_State :: struct {
	name:     string,
	timeline: engine.Ref_Local `ref:"PlayableDirector"`, // a director in this file
	speed:    f32,
	wrap:     Timeline_Wrap,
	fade:     f32, // default cross-fade duration INTO this state
}
```

A state binds nothing but its timeline. What that timeline drives is each
track's own `target` (see Bindings).

`fade` belongs on the state rather than at the call site. Without it every
caller hard-codes a duration and retuning how a transition feels is a code
change.

## The States tree

`plugins/animation/editor/inspector_timeline_animator.odin` draws `layers` in
the inspector, and the field is `inspect:"-"` so the reflected field loop skips
it. It is the same tree the Animation component gets
(docs/AnimationComponent.md, "The States tree"), one level shallower: a
`Timeline_State` is a flat entry in its layer rather than a node with a parent
and a union of kinds, so Add is a plain button rather than a menu of variants.

```
States
├─ Layer 0  [name]                          [Add State]
│    Weight  ──●────
│    ├─ Idle                            [▶] [x]
│    │    Timeline  <reference picker>
│    │    Speed / Wrap / Fade
│    └─ Swing ...
└─ [Add Layer] [Remove Layer]
```

The timeline field picks like every other reference field, filtered to
`PlayableDirector`.

It gets all of that from its TYPE. The field was a bare `engine.PPtr`, which
nothing registers a drawer for, so the reflected loop recursed into it and drew
`local_id` and `guid` as raw numbers. PPtr is the storage primitive; `Ref` and
`Ref_Local` are the reference types built on it (docs/ReferenceHandles.md), and
only those get the reference drawer, `ref:` filtering, and handle resolution
from the scene loader.

`Ref_Local` rather than `Ref`, so a timeline is a director **in the same
file**. The cross-asset form existed and was never used: no scene set a
timeline guid and no test covered the branch, so the instantiate path and the
`owned` flag that destroyed what it created were dead in every configuration
that ships. Sharing a state set between objects is what putting this component
in a prefab already does, and the timelines travel inside that prefab with it.
If a timeline ever does need to live in another asset, the field becomes an
`engine.Ref` and `_ta_state_root` grows an instantiate branch back.

The state names the **director**, not the object carrying it, and
`_ta_state_root` takes its owner as the timeline root — the same step
`_ta_target_transform` takes for a bound target. Both reference fields on the
component now have the same type and resolve the same way.

Every value row draws through `inspector.custom_field_row`, so each drag or
assignment is one undo step, and on a prefab instance the commit records an
override on the whole `layers` field — a state has no path from the component
base, which is the granularity the undo step records too — with the override
marker and the right-click Revert / Apply menu the generic inspector gives any
field. Add, remove and rename have no gesture and use
`inspector.structural_edit_begin/end`. See docs/Undo.md, "Custom rows draw
through `field_edit_row`".

A state added here is given its id immediately by `animator_state_next_id`,
rather than left at 0 for `_ta_ensure_ids` to fill at build time: a row has to
key a widget the moment it appears, and two rows holding 0 would collide.

Alt-click a layer to collapse or expand every state under it, as in the
hierarchy.

**Play works in both modes, through different paths.** Simulating, the button
plays the state on the live component and `timeline_animator_tick` advances it.
In edit mode nothing ticks the animator, so the same button starts a PREVIEW:
pose the world right before the scene render, put it back right after
(`moonhug:editor/preview`, docs/PlayableGraph.md step 5). The world holds
authored values for the rest of the frame, so saves, undo and the inspector
never see the pose, and there is no preview state to revert when it ends.

The advance is `timeline_animator_step`, the same proc the runtime tick calls,
in `.Preview_Play` mode — crossings and audio are real, game scripts stay
silent. Sharing that proc is the point: a preview with its own advance would
drift from play mode one fix at a time. Three things bracket it:

- `timeline_animator_ensure_graph` first, because refreshing defaults needs the
  bindings and the graph is what holds them.
- `timeline_animator_refresh_defaults` re-reads each output's default pose from
  the live transforms, so a preview restores what the object holds NOW rather
  than what it held when the graph was built.
- `timeline_animator_release` on stop, or the Animation components the preview
  drove stay flagged `timeline_driven` and refuse to play themselves.

One animator poses as many objects as its timelines drive, so all of those walk
every output rather than a single binding. Starting a state preview stops the
animation window's clip preview: the preview stack unwinds correctly either
way, but two posers at once is confusing and both buttons mean the same thing
to the user.

Under each state's own fields sit its timeline's **tracks**, one row each,
showing the track's binding field — the animation track's `target`, the audio
track's `source` — as `Track_Desc.binding_field` names it. This is the reason the
tree exists: every object a character depends on is read and edited in one
place. But the fields live on the tracks. Each row pushes the TRACK component
as the undo owner and records any prefab override against it, so editing here
is editing the track, and the Sequencer window shows the same value.

A row like that is a PROXY: it draws a component the inspector is not drawing,
so it addresses the field on that component — `inspector.inspect_comp` +
`property(p, desc.binding_field)`, docs/InspectorProperty.md — and the
property carries the track's own undo owner and prefab context, host and local
id together. Inheriting the animator's context is silently wrong. The host picks which
prefab an override lands on, and a local id from another namespace does not
fail the lookup: `nested_scene_locate_root_override` projects it into the
host's namespace, where it names an unrelated object. The animator is often
plain scene content driving tracks that are not, in which case the animator's
context would record no override at all.

A dedicated window is a later convenience, not a prerequisite.

Runtime state per playing state:

```odin
Animator_State :: struct {
	state:  int, // index into the layer's states
	weight: f32,
	fade_from, fade_target, fade_t, fade_dur: f32,
	nodes:  [dynamic]struct{ output: int, node: Playable_Handle },
	time:   f32,
	done:   bool,
}
```

The bookkeeping is single. Only the weight write fans out.

## API

Names resolve to handles once, then gameplay uses handles:

```odin
State_Id :: distinct i32

animator_find         :: proc(a: ^TimelineAnimator, name: string) -> (State_Id, bool)
animator_play         :: proc(a: ^TimelineAnimator, s: State_Id, fade: f32 = -1)
animator_stop         :: proc(a: ^TimelineAnimator)
animator_state        :: proc(a: ^TimelineAnimator, layer := 0) -> (s: State_Id, normalized: f32, done: bool)
animator_layer_weight :: proc(a: ^TimelineAnimator, layer: int, w: f32)
```

- `fade` of -1 uses the state's own duration, 0 or less is a hard cut.
- The layer is implicit. A state belongs to exactly one layer, so `play`
  resolves it the way `_anim_layer_of` resolves a clip's layer today.

There are no parameters, no conditions and no transition graph. Switching is
ordinary gameplay code calling this API. The state table is a binding table,
not a rule engine.

## Build and validation

The output set is built once, when the graph is built, so every binding
captures its default pose at a deterministic moment.

- Walk every state's timeline; for each animation track take the object it
  drives (its `target`'s owner, else the director's own object). The distinct
  set is the output set.
- Two POSE outputs whose subtrees overlap is an authoring error
  (`Overlapping_Pose`, reported against the inner object). Other kind pairs
  on the same object are fine.
- A track whose target appears after the build is inert until the next
  rebuild; an edit to `layers` triggers one.

The set derives from the timelines' own data, so there is nothing to keep in
sync and nothing that can be bound but unused.

## What changes in existing code

- `Playable_Graph` carries `outputs` instead of a single `root`, and
  evaluation pulls per output instead of returning a pose with scripts on the
  side. `Playable_Output` becomes one entry in that list rather than a graph
  of its own. This is finishing docs/PlayableGraph.md, not changing it.
- The animation package owns one graph per director and resolves it internally,
  since `Track_Ctx` cannot name a `Playable_Graph`. When audio becomes a real
  output kind the audio package cannot import animation either, so
  `Playable_Graph` has to move somewhere both can reach.
- `Track_Desc` gains `binding`, so a driver's inspector can show a track's
  target field without importing the track's package.

A standalone director keeps working unchanged, and so does a director under an
animator — its tracks resolve the same targets either way.

## Idea: published properties

Not adopted. Recorded because it subsumes routing, and the choice between it
and the route table above should be made once rather than drifted into.

A node-based shader editor holds many nodes, and only a few become properties
in the material inspector. The author picks which internal values are public
and names them. Everything else stays sealed.

The same shape fits here:

| shader editor | here |
| --- | --- |
| the graph, many nodes | the timeline prefab, many tracks and clips |
| exposed property | a published property |
| material | a state |
| material inspector | the state inspector |

Under this model a target reference is one property TYPE, not the mechanism. A
clip's duration, a tween's endpoint, an audio volume and a track's target are
all equally promotable, and the per-track binding rows the inspector draws
today become one case of a general override.

```odin
// Declared on the timeline's director root — the published interface.
Timeline_Property :: struct {
	name:          string,      // shown in the state inspector
	target:        engine.PPtr, // which node inside the prefab
	property_path: string,      // which field on it
}
```

A property is INTERNAL by not being listed. Listing it makes it public, and a
listed property with a value already set inside the prefab is public with a
default — the timeline plays standalone and a state overrides it only when it
wants something different.

The machinery exists. `Override{target, property_path, value}` and
`nested_scene_apply_overrides` (engine/nested_scene.odin) are a state's value
list already. What this idea adds is the FILTER: prefab overrides may hit any
property path, a published list curates a subset and gives each one a name.

This is the same idea as the EXPOSED PARAMETERS `docs/PlayableGraph.md`
specifies for the future graph asset — named inputs a driver writes instead of
poking node indices. One is at the graph level and one at the timeline level.
They should be decided together, or they will be designed twice with different
rules for naming, defaults and visibility.

Two things to weigh before adopting it:

- **Overrides land at instantiate time.** `nested_scene_apply_overrides`
  rewrites raw bytes, so a state sets its timeline's published values when the
  instance is created and cannot change them afterward. That covers routing,
  durations and volumes. It is not a runtime parameter system.
- **It is a bigger authoring surface.** The route table solves one problem with
  two strings per row. This solves a general problem and needs a property
  editor on the director, a value editor on the state, and a type story for
  every promotable field.

## Sample

`packages/animation/samples/timeline_sample` (installed as the
`packages/timeline_sample` symlink) ships `timeline_animator_demo.scene`
beside the sequencer's `timeline_demo.scene`:

```
TimelineAnimatorDemo    TimelineAnimator + TimelineAnimatorDemo (sample script)
├── Camera
├── Light               directional, or a lit material renders black
├── Hero
│   ├── Body            Animation          <- targeted by the Body tracks
│   │   ├── Torso
│   │   ├── Head
│   │   ├── ArmL
│   │   └── ArmR
│   └── Sword           Animation          <- targeted by the Prop track
│       └── Blade
├── idle                director -> one animation track, target Body
└── swing               director -> two animation tracks, targets Body and Sword
```

Everything is the built-in cube with the default material, so the scene needs no
imported asset and is visible the moment it opens. A box RIG also keeps the
demo readable: every channel moves a transform you can see in the hierarchy.
The `animation_sample` package is the skinned counterpart — an imported
character posed by the same clip path through `SkinnedMeshRenderer`.

Two things the sample exists to show, neither of which a single-clip player can
do:

- **Swing drives two targets from ONE state.** Its timeline has an animation
  track targeting Body and another targeting Sword, so one weight and one fade
  move the arm and the sword together.
- **Idle and Swing cover different objects.** Idle touches the body only, so
  going back to it leaves nothing driving the Sword and it settles toward its
  bind-time pose instead of holding. That is the partial-coverage behaviour in
  Concerns, made visible on purpose rather than designed around.

Channels target by NAME PATH from the Animation's owner — "ArmR" is a child of
Body — so the sample exercises the hierarchy walk, which a single cube does not.

`timeline_animator_demo.odin` is the part a game writes: a component with
inspector buttons (Idle, Swing, Stop) that resolve a state by name and call
`animator_play`. Press Play and click them. Passing no duration lets each
state's authored `fade` decide, so retuning how a switch feels is an inspector
edit.

Idle LOOPS and Swing plays ONCE. When Swing finishes, the script polls
`animator_state`'s `done` and hands back to Idle — which is the shape the
design asks for: no transitions in the data, a driver deciding what follows
what. The one flag it keeps is "a hand-back is already in flight", so the fade
is started once instead of restarted every frame.

`test_timeline_animator_demo_scene_loads` loads the scene, checks the
wiring, and plays a state through to a posed transform. Worth knowing why it goes that far: the
first version asserted only that the scene parsed and the names resolved, and
it passed while the animator posed nothing, because the sample's clips are not
in the test asset DB. An assertion that the object actually MOVES is the only
one that could not pass vacuously.

## Non-goals

- No transition graph, conditions or parameters.
- No blend trees. A state is a timeline, and a timeline already blends its own
  clips through track ease ramps.
- No replacement for `component_Animation`.

## TODO

In dependency order. Each MVP item is a prerequisite of the ones under it.

### MVP — two states cross-fading across two targets

1. ~~**Graph carries a list of outputs.**~~ DONE. `Playable_Graph.outputs`
   replaces the single `root`, `playable_graph_tick` pulls per output, and
   `playable_graph_evaluate` takes an explicit root so it stays a pure
   primitive. `_graph_bind` walks only the subtree reachable from that root,
   so a binding never carries a sibling output's channels.
2. ~~**Graph ownership moves up a level.**~~ DONE, with one correction to the
   plan: the arena cannot ride on `Track_Ctx`. That type lives in the
   sequencer package, which never imports animation, so it cannot name a
   `Playable_Graph`.

   The animation package keeps the arena instead, keyed by the director's
   transform (`_director_arenas`, track_animation.odin). One graph per
   director, one output per distinct target, a layer mixer at each output's
   root, and each track attaches its own mixer there in track order. The
   sequencer is unchanged.

   A track flushes its OWN output at the end of its tick rather than one pass
   flushing the arena, because the editor scrub and preview call
   `director_evaluate_at` directly and there is no post-evaluation hook.
   Tracks sharing an output each flush it, and the last to tick produces the
   final pose. Retargeting flushes the abandoned output once, or the object it
   was posing stays frozen — outputs are only ever flushed by a track that
   feeds them.

   This fixed a live bug. Two animation tracks aimed at one object used to
   own a graph each, so the second resolved its partial weight against a
   bind-time default captured on the first evaluation and never refreshed.
   They agree on frame one and drift apart after it.

   When TimelineAnimator arrives it replaces the arena lookup — the graph
   comes from the animator instead of being created per director. Same
   package, so that stays internal too.
3. ~~**The component and its graph skeleton.**~~ DONE.
   `plugins/animation/component_TimelineAnimator.odin` — fields, `reset_`,
   `cleanup_`, a lazily built graph guarded by `graph_ready`, and the tick. One
   output per bound target, a layer mixer at each output's root, one mixer per
   layer under it, layer weights pushed every tick since they are authored
   data.

   Two decisions worth knowing. Outputs come from the tracks' own targets,
   read at build, rather than from what states reach at runtime, for the
   deterministic-capture reason above. And an animator with nothing attached
   to any layer mixer does not apply at all — an empty pose applied every frame
   would write bind-time defaults over whatever else poses the object.
4. ~~**Target keys.**~~ Built, then REMOVED. Tracks were routed through named
   slots the animator bound to objects; a track's own target was ignored under
   an animator. Replaced by the tracks' own targets as the only binding, with
   the animator's inspector drawing those fields per state — see Bindings and
   "Why not keys" for the three reasons.

   The `timeline_driven` handshake follows the levels rule with one wrinkle: an
   IDLE animator RELEASES its targets rather than holding them. Claiming
   unconditionally would mean binding a target silently freezes the object
   until states exist, and every level is supposed to work with nothing above
   it configured. A disabled or destroyed animator releases too.

   Level 1 (a state's route) and the live use of level 2 both need a
   TimelineAnimator that owns a director, which is item 5. Until then `key` is
   stored and inert, and tracks resolve through levels 1-3 exactly as before.

   `TrackAnimation` gained `cleanup_TrackAnimation` — adding a string made it
   an owning component, which a contract test enforces.
5. ~~**State instances.**~~ DONE. A state points at its timeline with a
   `PPtr`, which covers both authoring modes:

   * CROSS-ASSET (guid set) — a prefab. The animator instances it under itself
     with `scene_instantiate_guid` and OWNS the instance, so the prefab system
     supplies variants and per-instance overrides.
   * LOCAL (guid zero, local_id set) — a timeline already in the scene,
     adopted where it stands and never destroyed. A timeline can be authored in
     place without making an asset first, which is what "every level works with
     nothing above it configured" asks for.

   Either way the state gets one mixer per output under its layer's mixer at
   weight 0, and its director is ADOPTED.

   Adoption is what makes a state part of the animator rather than a separate
   performance: the director's tracks build into the animator's graph under
   those mixers, resolve their output by `key` instead of by their own
   `target`, and never apply a pose — the animator flushes once, after every
   state has set its weights.

   Parking is a REGISTERED CHECK, not a flag.
   `director_register_drive_check` lets a driver in another package answer "I
   own this director", and the animation package registers one that reports
   adopted arenas. A `driven: bool` on `PlayableDirector` was the first
   attempt and is not viable — see Concerns.

   Not covered yet: nothing sets a state's weight above 0, so no state
   actually plays and the cross-asset instancing path has no test. The local
   path and the adopted key routing are both tested. Weight and cross-fade are
   item 6, and they are what make a state audible.
6. ~~**Weight and cross-fade.**~~ DONE. One weight per state, written to one
   mixer input per output it reaches, so a single fade moves the whole
   performance. The fade bookkeeping is the weight-continuous port of
   `component_Animation`: interrupting a fade retargets from the CURRENT
   weights, so nothing snaps and no snapshot is kept.

   `animator_find`, `animator_play`, `animator_stop`, `animator_state` and
   `animator_layer_weight`. A `State_Id` packs layer and index, so a caller
   resolves a name once and then holds a handle.

   There is no separate cross-fade call. `animator_play(a, s, fade)` covers
   both: -1 takes the state's authored duration, which is the point of
   authoring one, and anything at or below 0 is a hard cut. A cut is a fade of
   length 0, so one entry point is enough.

   **Play always starts the target at time 0.** The fade path once cleared
   `done` without rewinding, so a one-shot worked the first time and never
   again — it resumed at its end, reported done on the next tick, and handed
   straight back. Resuming mid-state would be a separate argument if anything
   ever needs one.

   Two ordering rules the implementation depends on:

   * Fades advance BEFORE the "is anything playing" check, or a fade starting
     from weight 0 reads as idle, the tick skips, and the fade never gets a
     first frame.
   * "Playing" means a state carries weight, not that states exist. An
     animator holding only silent states applies nothing and releases its
     targets, because writing an empty pose every frame would push bind-time
     defaults over whatever else poses the object.

   Known gap: a Once timeline that reaches its end collapses to the default
   pose instead of holding its last one. At `t == duration` a timeline clip's
   weight is 0, so the state contributes nothing. `component_Animation` holds
   the final pose in the equivalent case. See Concerns.
7. ~~**API.**~~ DONE with item 6, and one call shorter than planned — see
   above.
8. ~~**Tests.**~~ DONE, minus one. `timeline_animator_problems` finds authoring
   errors when the graph is built: a track asking for a key nothing binds, and
   two pose outputs whose subtrees overlap. Reported rather than fatal, since
   wrong authored data is not an invariant violation — but reported EARLY,
   because the alternative is a character that silently never moves.

   Covered: an interrupted fade stays continuous and still lands on the third
   state, a state's speed multiplies the animator's, an unbound key is
   reported, overlapping pose outputs are reported.

   NOT covered: "a Once state holds its last pose", because it does not. See
   Concerns.

### Next

1. **Script and audio as real output kinds.** Today scripts leave evaluation
   through an out-param and audio leaves through `Track_Desc.tick`. Both
   become outputs pulled like poses, which is what docs/PlayableGraph.md
   specifies and what makes weight reach them the same way.
2. **Weight policy per non-pose track kind.** Blocked on the item above for
   plumbing, and on real content for the rules.
3. **Editor preview.** Scrubbing a TimelineAnimator the way the animation
   window scrubs a clip, through the same bind-time default capture.
4. **Routing UI.** A dropdown of a timeline's actual tracks instead of a typed
   key.
5. **Published properties.** Decide it against the route table rather than
   drifting into one of them.
6. **Layer masks.** Only if content appears that authors a full-body timeline
   for partial use.
7. **Two animators keying one component.** A guard for the case the build check
   cannot see.

## Open questions

- **What fractional weight means for a non-pose track.** The plumbing is
  settled — every track kind receives the weight through its script node. The
  policy is not. Audio scales volume. Activation is a bool, so a threshold or
  last-writer-wins, and both are arbitrary. Firing a marker at weight 0.02 is
  wrong. This wants two real timelines that get cross-faded before the rules
  are fixed.
- **Enumerating a timeline's tracks for the routing UI.** A route row is
  authorable as plain text in the regular inspector, so nothing blocks on
  this. Offering a dropdown of the timeline's actual tracks means reading a
  prefab's track nodes without instantiating it, and `director_tracks` needs a
  live director and a built subtree. Published properties (below) remove the
  question by declaring the interface instead of deriving it.
- **What `timeline_driven` becomes.** An `Animation` bound as a pose target
  stops running its own playback, which is the flag's existing meaning. Under a
  TimelineAnimator it is set for as long as the component is a target rather
  than per tick, and nothing has decided who clears it when a track's target
  changes or the animator is disabled.
- **Whether an output component may be a target of two animators.** Two
  TimelineAnimators keying the same `Animation` is the same clobbering problem
  as two overlapping pose outputs, but it crosses component boundaries so the
  build check cannot see it.

## Concerns

Known risks with a position, recorded so they are not argued twice.

### A finished Once state stops posing instead of holding

(Partly addressed: a Once state now sets `done` at its end and holds its
playhead there, so a driver can hand back to another state. What follows is
about what the pose does if nobody hands back.)

A timeline clip covers `[start, start+duration)`, so at exactly the end its
weight is 0. A state whose wrap is Once clamps its playhead to the timeline
length, lands on that boundary, and contributes nothing — the object falls back
to the bind-time default rather than holding the last pose.

`component_Animation` does not have this problem: a done clip node samples at
its length and the sampler clamps to the last key, so the pose holds. The
difference is that a timeline adds a clip-weight layer underneath.

Not fixed. Clamping to just under the length would work and is the kind of
epsilon that rots. The real answer is probably for a Once timeline to hold its
last evaluated pose explicitly, which wants the same decision as "what does a
finished state do" in the play API.

### Changing a component's fields broke scene round-trip — fixed

Adding one field to almost any component made `scene_file_unmarshal` fail with
`Invalid_Data`, so a simulate Stop could not restore its snapshot
(`test_sim_start_stop_round_trip`). It looked like a serialization problem and
was sidestepped twice: the director's parking flag became
`director_register_drive_check`, and a sample's cycle timer moved to file-scope
statics.

It was not serialization. The snapshot BYTES were corrupt — a guid string
truncated mid-write, with valid JSON on both sides of it. `simulate._snapshot`
is a global that held the buffer `scene_serialize` returned, which comes from
`context.allocator`, so unrelated allocation churn between Start and Stop
rewrote bytes inside it. Changing any component's fields shifted that churn
enough to move the corruption in or out of the snapshot, which is why it looked
like the FIELDS mattered.

Fixed by pinning the snapshot and the scene path to the default allocator
(`simulate.odin`). The user-visible bug it was causing: Stop reporting "snapshot
restore failed" and leaving the scene in its simulated state.

One more symptom worth knowing: the failing test leaves
`moonhug/tests/fixtures/_test_sim_set_kept.scene` behind, and that stale file
then changes the result of later runs. Clean it before trusting a bisect.

### Default pose coverage — live, needs a policy

`animation_binding_refresh_defaults` re-captures defaults from the live
transforms, and the only caller is the editor's scrub preview. At runtime
defaults are captured once at bind and never move, which is deliberate: live
values fed back frame to frame drift.

The consequence is that a state animating a SUBSET of channels leaves every
other channel at the bind-time pose. Fading out of an upper-body state returns
the arms to the pose the object had when it bound, not to whatever the
incoming state wants. Two states with different channel coverage do not sum to
1 on the channels only one of them touches, so the uncovered part blends
toward a third pose nobody asked for.

This is not new. The Animation component's graph behaves the same way today,
so it is the established model rather than a regression. Timelines make it
more likely to show, because a timeline's tracks are heterogeneous by design
and two states are less likely to cover the same channels than two clips are.

It may need special treatment. Shapes worth weighing when it does:

- capture a state's defaults when it starts rather than at bind, accepting
  some drift in exchange for a correct fade-out target,
- let a layer declare the channel set it owns, so uncovered channels are left
  alone instead of blended toward the default,
- a per-state choice between the two, which is the setting other engines ship
  and the one users find hardest to reason about.

### Timeline instances are scene objects — deferred

A state instantiates a prefab, so N states on M animators is N*M parked
subtrees, each iterated by `director_run` every frame and each carrying real
transforms and components.

Accepted for now. The scene tree is what gives overrides, variants and
per-instance binding for free, and those are worth more than the cost while
the feature is unproven.

The later optimization has a known shape rather than being an open "denser
format": a GRAPH TEMPLATE built straight into the animator's arena, with no
scene subtree at all. The prefab instance exists today only to hold authoring
data — its graph contribution is already inlined into the arena the moment
tracks attach. Replacing the instance means replacing where the authoring data
is read from, not how evaluation works.

### API surface — deferred

The API here is smaller than `component_Animation`'s, which has queued
cross-fade and this does not. That may be right: a small API is the goal, and
the older component's may be the one that is overgrown. Decided after both
have been used, not before.
