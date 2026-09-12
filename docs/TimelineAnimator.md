# TimelineAnimator

> Design. Nothing here is implemented. The pieces it builds on are:
> the playable graph (packages/animation/playable_graph.odin), the animation
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

## Target keys

One naming hop, in three steps.

1. **The scene already holds the output components.** An `Animation` receives a
   pose, an `AudioSource` receives audio. Nothing is marked or tagged — the
   component that receives a kind of output is the component that already does
   that job.
2. **TimelineAnimator gives them keys.** Its `targets` list maps a key name to
   one of those components.
3. **A timeline's tracks name keys.** A track says "Body", and which component
   that is depends on the TimelineAnimator playing it.

The timeline prefab is the shared part, and it names only keys. The component
decides what those keys mean, so one timeline serves several animators binding
different objects. The same shape a key binding table uses: the map declares
actions, the instance binds devices.

**The output kind is the component type.** It is never declared. A track bound
to an `Animation` produces a pose output, a track bound to an `AudioSource`
produces an audio output, and a key bound to the wrong component type is an
authoring error caught at build.

## Levels of configuration

Several mechanisms say "another driver owns your playback": `timeline_driven`
on `Animation`, `_director_is_control_driven` for a director inside a control
track's clip, and the parking TimelineAnimator does to a state's director.

These are not three solutions to one problem. They are LEVELS. The higher a
driver sits, the more generic it is, and a lower level overrides the one above
it wherever both apply:

- `Animation` running its own clip is the most generic.
- A timeline's animation track overriding that component is more concrete.
- A TimelineAnimator owning that timeline is more concrete still.

A new driver added later takes its place in that order rather than inventing
its own handshake.

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

- **Kind** — what it writes. Pose, script callbacks, audio commands. Taken
  from the target component's type, never declared.
- **Target** — the component it writes to.

Several outputs of the same kind is the normal case, not an edge one: a
performance that poses three characters has three pose outputs. Outputs are
derived rather than declared — the graph holds one per target some track
actually reaches, so a key nothing routes to costs nothing.

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

The current implementation has one output and welds it to the graph:
`playable_graph_evaluate` returns a pose and collects scripts through an
out-param, and `Playable_Output` pairs one graph with one binding. That is the
side-channel shape docs/PlayableGraph.md warns against, and straightening it
is the first piece of work this design needs.

## The tree

```
Graph
├── Output (pose, "Body")       key "Body" -> an Animation component
│   └── Layer_Mixer
│       ├── Mixer  layer 0
│       │   ├── Mixer  state "Idle"   w = 1 - fade
│       │   │   ├── Mixer  track      (clip ease weights)
│       │   │   └── Mixer  track
│       │   └── Mixer  state "Run"    w = fade
│       └── Mixer  layer 1            w = layer weight
├── Output (pose, "Face")
│   └── Layer_Mixer
│       └── ...
└── Output (audio, "Voice")     key "Voice" -> an AudioSource
    └── ...
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
node decides what it means. `Script_Playable.process` already receives it, so
a track that produces side effects rather than a pose — audio, activation,
markers — builds a script node and reads the weight there. There is no path
out of the manager that skips it.

Cross-fade is weight-continuous, the same rule `component_Animation` uses:
fading to C in the middle of an A to B fade retargets A and B toward 0 from
their CURRENT weights while C rises. No snapshots, and weights that summed to
1 still sum to 1.

## Keys

A track resolves its target in this order:

1. the state's route for that track
2. the track's own `key` field
3. the standalone chain that exists today — explicit target, the director's
   own Animation component, then the director's transform

Level 2 is the default so a timeline that drives one object needs no routing
at all. Level 1 is what lets the same timeline serve several states with
different targets.

"Idea: published properties" below is the alternative to this whole section.

A route identifies its track by `Local_ID`, not by name, so renaming a track
does not break a state. The state already holds the timeline's guid, so the
route stores only the id:

```odin
Track_Route :: struct {
	track: engine.Local_ID, // the track node inside this state's timeline
	key:   string,          // target slot it drives
}
```

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
	targets:    [dynamic]Target_Binding, // key -> output component

	// runtime, not serialized
	graph: Playable_Graph,
	rt:    [dynamic]Layer_Runtime,
}

Animator_Layer :: struct {
	name:          string,
	default_state: string,
	weight:        f32,
	states:        [dynamic]Timeline_State,
}

Timeline_State :: struct {
	name:     string,
	timeline: engine.Asset_GUID, // prefab whose root carries a PlayableDirector
	routes:   [dynamic]Track_Route,
	speed:    f32,
	wrap:     Timeline_Wrap,
	fade:     f32, // default cross-fade duration INTO this state
}

Target_Binding :: struct {
	key:    string,
	target: engine.Ref_Local, // an Animation, an AudioSource, and so on
}
```

`fade` belongs on the state rather than at the call site. Without it every
caller hard-codes a duration and retuning how a transition feels is a code
change.

The regular inspector is enough to author this. A dedicated window is a later
convenience, not a prerequisite.

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
animator_play         :: proc(a: ^TimelineAnimator, s: State_Id)
animator_cross_fade   :: proc(a: ^TimelineAnimator, s: State_Id, duration: f32 = -1)
animator_stop         :: proc(a: ^TimelineAnimator)
animator_state        :: proc(a: ^TimelineAnimator, layer := 0) -> (s: State_Id, normalized: f32, done: bool)
animator_layer_weight :: proc(a: ^TimelineAnimator, layer: int, w: f32)
```

- `duration` of -1 uses the state's own `fade`.
- The layer is implicit. A state belongs to exactly one layer, so `play`
  resolves it the way `_anim_layer_of` resolves a clip's layer today.

There are no parameters, no conditions and no transition graph. Switching is
ordinary gameplay code calling this API. The state table is a binding table,
not a rule engine.

## Build and validation

The output set is built once from the `targets` list, not when a state fades
in, so every binding captures its default pose at a deterministic moment.

- Union the keys every state's timeline tracks ask for. Resolved through
  `targets`, that is the output set.
- A key with no binding in `targets` is an authoring error, reported at build.
- A key bound to a component of the wrong kind for the track that uses it is an
  authoring error.
- Two POSE outputs whose bound subtrees overlap is an authoring error. Other
  kind pairs on the same object are fine.
- A bound target that no state reaches is dead and harmless.

The `targets` list is serialized data on the component, so nothing has to be
discovered by walking the scene and the output set changes only when someone
edits that list.

## What changes in existing code

- `Playable_Graph` carries `outputs` instead of a single `root`, and
  evaluation pulls per output instead of returning a pose with scripts on the
  side. `Playable_Output` becomes one entry in that list rather than a graph
  of its own. This is finishing docs/PlayableGraph.md, not changing it.
- `Track_Ctx` gains the output the track builds into. `_animation_track_build`
  uses the provided graph instead of calling `playable_output_init`, and
  `_animation_track_tick` does not apply a pose when it does not own the
  output.
- `TrackAnimation` gains `key`. Standalone directors pass no manager and
  resolve through the chain they use today.

A standalone director keeps working unchanged.

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
all equally promotable, and `Track_Route` becomes one case of a general
override.

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

Two things to weigh before adopting it:

- **Overrides land at instantiate time.** `nested_scene_apply_overrides`
  rewrites raw bytes, so a state sets its timeline's published values when the
  instance is created and cannot change them afterward. That covers routing,
  durations and volumes. It is not a runtime parameter system.
- **It is a bigger authoring surface.** The route table solves one problem with
  two strings per row. This solves a general problem and needs a property
  editor on the director, a value editor on the state, and a type story for
  every promotable field.

## Non-goals

- No transition graph, conditions or parameters.
- No blend trees. A state is a timeline, and a timeline already blends its own
  clips through track ease ramps.
- No replacement for `component_Animation`.

## TODO

In dependency order. Each MVP item is a prerequisite of the ones under it.

### MVP — two states cross-fading across two keyed targets

1. **Graph carries a list of outputs.** `Playable_Graph.outputs` replaces the
   single `root`, and evaluation pulls per output instead of returning one
   pose. `Playable_Output` becomes one entry rather than a graph of its own.
   Existing playable graph tests keep passing. Nothing else can start until
   one graph can write to more than one target.
2. **A track builds into a provided output.** `Track_Ctx` carries the graph and
   the parent handle to attach under. `_animation_track_build` uses them
   instead of calling `playable_output_init`, and `_animation_track_tick` does
   not apply a pose when it does not own the output. A standalone director
   passes nothing and behaves as it does today. Without this, two timelines
   apply separately and cannot blend at all.
3. **The component and its graph skeleton.** Fields, `reset_`, `cleanup_`,
   graph init and teardown, the per-frame tick. One layer mixer at the root
   and one mixer per layer. No states yet.
4. **Target keys.** The `targets` list, key resolution to an output component,
   one graph output per reached target. `TrackAnimation.key` and the route
   lookup, with the existing fallback chain underneath. An `Animation` bound
   as a target sets `timeline_driven` so it stops driving itself.
5. **State instances.** Instantiate each state's timeline prefab with
   `scene_instantiate_guid`, park it so `director_tick` never runs on it, and
   drive its time from the state.
6. **Weight and cross-fade.** One weight per state, fanned to one mixer input
   per output it reaches. The weight-continuous fade bookkeeping is a port of
   what `component_Animation` already does.
7. **API.** `animator_find`, `animator_play`, `animator_cross_fade`,
   `animator_layer_weight`, `animator_state`.
8. **Tests.** Weights sum to 1 through a fade interrupted by a third state. A
   Once state holds its last pose. A state advances at its own speed. An
   unbound key fails at build. Two overlapping pose outputs fail at build.

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
- **Whether a route names a track or a slot.** `Track_Route.track` is a
  `Local_ID`, so a state reaches inside the timeline prefab and names one of
  its nodes. Splitting one track into two then breaks every state that routed
  it. Naming a slot the timeline publishes keeps the internals free to change,
  and moves the breakage to renaming a published name, where it belongs. This
  is the small version of the published-properties idea below.
- **What `timeline_driven` becomes.** An `Animation` bound as a pose target
  stops running its own playback, which is the flag's existing meaning. Under a
  TimelineAnimator it is set for as long as the component is a target rather
  than per tick, and nothing has decided who clears it when the `targets` list
  changes or the animator is disabled.
- **Whether an output component may be a target of two animators.** Two
  TimelineAnimators keying the same `Animation` is the same clobbering problem
  as two overlapping pose outputs, but it crosses component boundaries so the
  build check cannot see it.

## Concerns

Known risks with a position, recorded so they are not argued twice.

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
the feature is unproven. A denser data format is a later optimization, taken
only once the feature has earned it.

### String keys across a prefab boundary — deferred

A timeline prefab is edited independently of every animator using it, so
adding or renaming a key breaks routes silently until something rebuilds.

Treated as a UX problem rather than a design one. It waits until the tool is
in use, along with the other problems that will surface then.

### API surface — deferred

The API here is smaller than `component_Animation`'s, which has queued
cross-fade and this does not. That may be right: a small API is the goal, and
the older component's may be the one that is overgrown. Decided after both
have been used, not before.
