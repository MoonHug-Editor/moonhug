# Animation component

Plays animation clips on a transform's hierarchy. One component owns one
PlayableGraph (docs/PlayableGraph.md) and drives it: it holds the playback
state, restructures the graph between evaluations, and advances time. The graph
itself stays a pure evaluator.

There is no state machine. What follows what is ordinary gameplay code calling
this API. What the component holds is the LIST of things that can be played.

```
Animation
├── clip                one clip, played on the first tick if play_automatically
├── play_automatically
├── wrap_mode           Default defers to the clip's own wrap, else Once or Loop
├── speed               scales time for every state on this component
└── layers              the states, as a tree per layer
```

## States

A layer holds a tree of ENTRIES. An entry is one state gameplay can play:

- **Clip** — plays one clip.
- **Blend1D** — blends its children along one axis by a value.

```
Layer 0
├── Locomotion   Blend1D, value 0.4
│   ├── Walk     at 0.0
│   └── Run      at 1.0
├── Idle         Clip
└── Death        Clip
```

Each entry carries:

| field     | meaning                                                     |
|-----------|-------------------------------------------------------------|
| `id`      | minted on add, never reused — what the play API takes        |
| `parent`  | another entry's id, 0 for a state directly on the layer      |
| `pos`     | placement in the PARENT's blend space (1D reads x)           |
| `name`    | what `animation_find` looks up                               |
| `variant` | `Clip_Entry` or `Blend1D_Entry`                              |

Ids rather than indices, because deleting a sibling shifts every index after it
and would silently repoint a play call at a different state.

`pos` lives on the CHILD, not as a threshold list on the parent. A child then
works under any blend kind without knowing which it is, and switching a blend
from one axis to two keeps every child's x.

### Why the tree is stored flat

`entries` is one array per layer and `parent` is an id, rather than each blend
holding its own children. A recursive union serializes and undoes badly here:
the JSON nests without bound, and an undo edit lands inside a union inside an
array inside a union, where a missing `register_pointer_type` makes it silently
no-op. One array is one undo edit and one JSON array, and it still draws as a
tree.

`Anim_Entry_Variant` is `#no_nil` with `Clip_Entry` first. A nil union marshals
to bare `null`, which the generic union reader cannot read back, and the whole
owning component is then preserved verbatim as an unknown one — the object reads
"Missing Component" and every field vanishes because one variant was unset. An
empty clip entry is the natural zero, and it is what an author gets when they
add a state before picking its clip.

Both variants carry a `@(typ_guid)`, and that is what gets the union
serialized: `union_gen` (a prebuild module) finds every hand-written union
whose variants all carry the tag and emits the guid-tagged marshaler
registration into that package's `unions_generated.odin`, so no package has to
remember it. Without the registration the default marshaler writes the active
variant's fields with no tag, which reads back as the zero variant: a blend
saved and loaded comes back a clip, quietly. A union with an untagged variant
is left alone and keeps the default marshaler.

## API

```odin
animation_play(a)                       // the `clip` field, from the start
animation_play_clip(a, clip, layer)     // a clip by guid, cut
animation_cross_fade(a, clip, dur, layer)
animation_cross_fade_queued(a, clip, dur, layer)
animation_stop(a)

animation_find(a, name) -> (id, ok)     // a state by name
animation_play_entry(a, id, duration)   // a state by id: clip or blend
animation_blend_set(a, id, value)       // move a blend along its axis
animation_blend_get(a, id)
animation_entry(a, id) -> ^Anim_Entry
```

`animation_play_entry` with `duration` 0 cuts, above 0 cross-fades. Playback
always starts at the beginning: a state asked for is a state from the top.

A blend's value lives on the AUTHORED entry and the runtime reads it every
tick, rather than being copied into the playing state. One field, one source of
truth — an inspector slider and a gameplay call are then the same edit, and
setting it on a state that is not playing decides where it starts.

## What the graph looks like

The tree is the authored shape. The graph holds only what is PLAYING, so the
two are deliberately different:

| authored            | graph                                             |
|---------------------|---------------------------------------------------|
| layer               | one input of the layer mixer                      |
| Blend1D             | a mixer, built with ALL its children at once      |
| Clip                | a clip node, built only when it plays             |
| a state not playing | nothing at all                                    |

```
layer mixer
└── layer 0 mixer
    └── Locomotion mixer        weight = the state's fade weight
        ├── walk clip node      weight from the 1D rule
        └── run clip node
```

A blend is ONE state with one weight: its mixer takes the fade, and the parent
weight premultiplies down the subtree during evaluation, so fading a blend in
fades both children together.

That asymmetry is why the tree cannot be a view of the graph, and why the play
buttons in the inspector call the driver rather than touching graph nodes.

Every reader builds nodes through one primitive, `animation_entry_build`: the
driver for the states that play, and `animation_graph_build_authored` — which
the Playable Graph window draws and the scrub preview evaluates — for the whole
tree at once. One builder, so the window cannot show a shape the component
would not play.

Nested blends are not built. A blend child that is itself a blend is skipped
rather than flattened, so the graph never silently means something other than
the tree.

## Blend1D

Children are sorted by `pos`. The two bracketing the value share the weight
linearly, and the ends clamp — past the last child the last child owns the pose,
rather than falling off toward the default pose.

**Children share one phase.** A blend does not run its children on their own
clocks. It holds a normalized `phase` in 0..1 and samples each child at
`phase * child_length`, so a 1.07s walk and a 0.77s run keep their footfalls
together. Sampling both at the same absolute seconds is what makes blended
locomotion slide.

The phase advances at the BLENDED cycle length:

```
cycle  = lerp(len_lo, len_hi, k)      // the same k the weights use
phase += dt * speed / cycle
```

so leaning toward the run speeds the cycle up on its own, which is what makes a
walk-to-run blend read as one gait rather than two.

Wrap follows the first child's clip, the same "defer to the clip" rule a single
clip state uses — a blend has no clip of its own to ask.

## Fades

Fades are weight-continuous, which is what makes interruption smooth with no
snapshot machinery. Cross-fading to C in the middle of an A to B fade just
retargets: A and B fade to 0 FROM THEIR CURRENT WEIGHTS while C fades in.
Weights on a layer sum to 1 whenever they summed to 1 before, and the first
fade-in on an empty layer blends up from the default pose.

Fades run on real time and ignore `speed`.

A Once state that runs past its end holds its final pose (`done`) until
everything is done or something replaces it. When every state is done the
component stops evaluating and freezes on that pose.

## Layers

The index in `layers` is the layer index, and a higher layer overrides a lower
one wherever it animates — the layer mixer stacks bottom-up over the default
pose.

`play` and `cross_fade` called without a layer argument resolve the clip's layer
from the authored entries (a clip inside a blend counts: the blend is what
plays, but the layer is the same). An explicit layer argument overrides, and an
unlisted clip lands on layer 0.

## The States tree

`plugins/animation/editor/inspector_animation.odin` draws `layers` in the
inspector, and the field is `inspect:"-"` so the reflected field loop skips it —
a tree of arrays of unions is the shape those rows draw worst.

Each row carries what its kind actually has: a clip entry gets a clip picker, a
blend gets a value slider spanning its children's positions plus a row per
child with that child's position on the axis. Add and remove go through
`inspector.structural_edit_begin/end`, so every edit is one undo step and is
recorded as a prefab override.

The play button calls `animation_play_entry`. The editor does not tick, so it
takes effect while simulating.

Removing a blend takes its children with it. A child whose parent is gone is
unreachable, unplayable, and invisible in the tree.

## The Animation window

`plugins/animation/editor/view_animation.odin` is the clip EDITOR: a dope sheet
and curve view over one clip's channels, with recording, add-property and
per-key editing.

It is component-bound, not asset-bound. `_pv_target` walks up from the selection
to the nearest `Animation`, so selecting a child bone keeps the window on the
animated root, and the clip dropdown lists every clip reachable from that
component — the `clip` field plus every clip entry on every layer, blend
children included. A clip appears there because something references it, not
because it exists in the project.

Edits go through an `inspector.Asset_Doc`: Save writes the document to the
`.anim` file, and unsaved edits revert. The scrub preview evaluates the
component's full authored graph with the scrubbed clip at weight 1 and
everything else at 0, so the preview path is the graph the component actually
plays and the Playable Graph window shows the real topology.

## Sample

`packages/animation/samples/animation_sample` (installed as the
`packages/animation_sample` symlink) ships `animation_demo.scene`: an imported
glTF character, a skinned mesh posed by `SkinnedMeshRenderer`, and one layer
holding a `Locomotion` blend over walk and run plus Idle, Jump and Death.

`animation_demo.odin` is the part a game writes. It plays states BY NAME and
pushes its `blend` field into the Locomotion blend every frame, the way a
character controller would push its own speed. Writing it every frame rather
than on change is deliberate: it is the shape real gameplay has.

`test_animation_demo_scene_loads` loads the scene, checks the tree survived
serialization, and plays the blend through to a posed joint. The scene is
hand-generated JSON carrying hand-written union tags, which is exactly the kind
of asset that rots silently.

## Non-goals

- No transitions, conditions or parameters. A blend reads one value that
  gameplay sets by id. One value feeding several blends is two calls.
- No 2D blends yet. `pos` is already a `[2]f32` and the union takes another
  variant, so adding `Blend2D_Entry` touches the weight rule and the drawer,
  not the data model.
- No nested blends. The data allows the shape, the graph builder refuses it.
- No replacement for the timeline. A timeline that drives this component sets
  `timeline_driven`, and the component's own playback stands down so the two
  never write the same transforms in one frame.
