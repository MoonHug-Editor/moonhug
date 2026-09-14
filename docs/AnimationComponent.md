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
| `wrap`    | Default defers to the clip, else Once or Loop                 |
| `kind` | `Animation_Entry_Clip` or `Animation_Entry_Blend1D`                              |

Ids rather than indices, because deleting a sibling shifts every index after it
and would silently repoint a play call at a different state. `TimelineAnimator`
follows the same rule — its `State_Id` is a minted `Timeline_State.id`, filled
in by `_ta_ensure_ids` for states added through the inspector's array rows.

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

`Animation_Entry_Kind` is `#no_nil` with `Animation_Entry_Clip` first. A nil union marshals
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

### Wrap

**The clip is the default and the state overrides it.** A walk cycle is cyclic
and a death is one-shot, so the motion usually knows — `AnimationClip.wrap` is
the answer most of the time, and an entry left at `Default` takes it. The state
overrides for the case one clip is played both ways.

The override sits on the STATE rather than the component on purpose. A
component holds Idle and Death at once, so one wrap for both can never be
right: a component-wide `wrap_mode = Loop` is what made Death loop in this
package's own demo, and removing that field is what fixed it. A clip played by
guid has no entry and takes the clip's wrap.

A **blend** reads its own entry, not any child's clip. Children share one
phase, so no single child's wrap is the blend's — a child's clip is only the
fallback when the blend says Default.

Other systems answer this differently and it is worth knowing why. A legacy
clip player overrides at three levels (clip, component, playing state). A
mecanim-style controller has no wrap on a state at all — looping is a clip
import setting, because the motion owns it. A timeline adds a separate
EXTRAPOLATION concept (hold, loop, ping pong) for what a track does outside a
clip's extent, rather than reusing wrap for it. We sit between the first two:
the clip owns the default, one level above overrides, and the coarse
component-wide level is gone.

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
animation_entry(a, id) -> ^Animation_Entry
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
the Playable Graph window draws, and which the editor preview evaluates for
both a clip scrub and a played state — for the whole tree at once. One builder,
so the window cannot show a shape the component would not play.

`animation_graph_build_authored` reports an `Animation_Authored_Leaf` per clip: the
`Animation_Blend_Child` the 1D rule needs, which top-level entry it belongs to, and
the chain it hangs from (`under`, `top`, `layer`). Lighting a clip inside a
blend means weighting that whole chain — the clip under the blend's mixer AND
that mixer under the layer — since a blend left at 0 reaches the pose with
nothing.

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

## The playing state

A playing state is `Animation_State_Runtime`: the fade fields and `done`, plus a
`kind` union of `Animation_State_Clip` (a clip and its clock in seconds) and `Animation_State_Blend`
(its children and a shared phase). Runtime only and never serialized, so unlike
the authored `Animation_Entry_Kind` it carries no guid and needs no marshaler —
but it is a union for the same reason, so neither kind holds the other's fields.

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

The play button never touches graph nodes. While simulating it calls
`animation_play_entry` and lets the next tick rebuild the graph. In edit mode
nothing ticks the component, so it drives the animation window's preview
instead — ONE preview in the editor, so a state and a clip scrub can never pose
the same object at once. Entering state mode ends a scrub, picking a clip in
the window ends the state, and the button turns into a stop while its state is
previewing.

A previewed blend runs exactly as a played one does: the same
`animation_blend1d_weights` and `animation_blend_sample`, on a graph built by
`animation_graph_build_authored`. So dragging a blend's value in the tree moves
the character in edit mode.

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

## TODO: clip settings move to the meta

**Decided: `wrap` and `frame_rate` leave the `.anim` file for `.anim.meta` as
importer settings, and extraction REPLACES an existing clip instead of skipping
it.** Both halves are one change — neither works without the other.

The reason is that a clip extracted from a model is a GENERATED artifact.
Extraction refuses to overwrite one today:

```odin
if os.exists(out) {
    fmt.printf("[Editor] Extract: %s exists, skipped (delete it to re-extract)\n", out)
    continue
}
```

So re-exporting the character from Blender cannot refresh its curves without
deleting the clip — which deletes its authored wrap along with them. Anything
that must survive a re-import cannot live in the file the re-import rewrites.

Every `.anim` does this, not only extracted ones. A hand-created clip has no
model behind it, but one rule beats two: an author looking for a clip's wrap
should never have to ask where the clip came from first. Unity splits exactly
here — imported clips keep their settings in the MODEL's meta, native `.anim`
assets keep theirs in the file — and the split is a thing people have to learn.

### Shape

`.anim` becomes an imported asset, the way audio and textures already are:

- an `@(phase={key=ImportersInit})` registration with
  `settings_tid = typeid_of(Animation_Clip_Settings)` holding `wrap` and
  `frame_rate`
- the meta gains `importer` and a settings blob, the shape
  `plugins/mhgui/assets/white.png.meta` already has
- the import BAKES the settings into the artifact, so `animation_clip_load`
  reads an artifact and the runtime never opens a meta
- the project inspector then shows the import-settings panel on its own
  (`_draw_import_settings_inspector` routes by importer), so `.anim` comes back
  OUT of `_is_inspector_asset` — the document routing added for clips is a
  stepping stone this replaces
- `AnimationClip.wrap` and `.frame_rate` come off the serialized struct.
  `length` stays: it is derived from the last key, not authored.

Extraction then drops the `os.exists` guard and writes the clip every time. The
meta is a separate file, so the settings ride through untouched — which is the
whole point of moving them.

### Migration

Every shipped `.anim` carries `wrap` in the file today (`BoxAnimated_0.anim` is
Loop, the character's nine are Once). A one-off pass moves each clip's value
into its meta and drops the field.

### Open

A hand-created clip (Assets/Create/Animation) has no source to re-import from —
its `.anim` IS the source. Simplest answer that keeps one rule: the importer
copies it through unchanged and its settings still live in the meta. Worth
confirming that reads well in the project inspector before committing to it.

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
