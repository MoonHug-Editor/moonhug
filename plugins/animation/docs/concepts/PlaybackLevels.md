---
title: "Playback levels"
description: "How an Animation component, a timeline's animation track and a TimelineAnimator stack, who owns the graph, and why bindings stay on the tracks"
weight: 40
tags: ["animation", "sequencer", "concepts"]
---

Three things can pose the same object: an [Animation](../components/Animation.md) component, a timeline's [animation track](../components/TrackAnimation.md) driving it, and a [TimelineAnimator](../components/TimelineAnimator.md) playing that timeline as a state. This page is how they stack and why. The track and the animator live in the plugin's `sequencer` subpackage and need the sequencer plugin.

## Each level is a default for the one above

A higher level overrides a lower one wherever both have a value, and every level works with nothing above it.

- An Animation playing its own clip is a default. A timeline track driving it overrides that, and the component's own playback stands down. An animator driving the timeline overrides that, and the timeline's director stops playing on its own.
- A track with no target drives its director's own object. A target overrides that.
- `Animation.timeline_driven`, `_director_is_control_driven` for a director inside a control clip, and the parking of a state's director are one rule in three places. A driver added later takes its place in the order instead of inventing its own handshake.
- Parking is a registered check, not a flag: `director_register_drive_check` lets a driver in another package answer "I own this director", and this plugin registers one that reports adopted directors.
- An idle animator releases its targets instead of holding them. Claiming them always would freeze an object as soon as it is bound, before any state exists.

## The highest level owns the graph

The highest level present owns the [playable graph](PlayableGraph.md), and everything below attaches a subtree under a handle it is given.

- A director's animation tracks share one graph, with one output per object they target, so two tracks aimed at one object stack.
- Under an animator the tracks build into the animator's graph instead, and the animator writes once after every state has its weight.

Weights blend only inside one evaluation, because a pose resolves partial weight against the default pose taken at bind time. Two timelines that each evaluate and write on their own, both at 0.5, do not cross-fade: the second write replaces the first. So the animator owns one graph and is the only writer.

- An output varies on two independent axes: its kind, what it writes, decided by the track that feeds it, and its object, the transform it writes to.
- The outputs are built once, when the graph is built, from the tracks' own targets. Every binding then takes its default pose at the same moment. Building outputs as tracks arrive would save an empty pose per frame and pay for it with defaults taken at arbitrary times, the harder bug.
- Overlap is checked per kind: two pose outputs whose hierarchies overlap clobber each other and are reported, while a pose and an audio output on one object never conflict.

## Bindings stay on the tracks

A track's own target is the only binding. An animation track names the Animation it drives, an audio track its AudioSource, under an animator or not. The animator reads those targets to size its outputs and only changes where a track's subtree hangs inside its one graph, never what the track drives.

Two things follow, and both are the prefab system doing the work:

- **A timeline is reusable across characters** by living inside the character's prefab. A second character is a second instance, and retargeting is a prefab override on a track's `target`.
- **A timeline needs no setup to play under an animator.** Author it, point its tracks at what they drive, and add a state naming it.

The animator's inspector draws every track's binding under the state that plays it, so a character's dependencies are edited in one place, but those rows edit the tracks' own fields. A row like that draws a component the inspector is not drawing, so it addresses the field on that component (`inspector.inspect_comp` plus `property(p, desc.binding_field)`, [InspectorProperty](/docs/core/InspectorProperty.md)), and the property carries the track's own undo owner and prefab context. Inheriting the animator's context would be silently wrong: the host decides which prefab an override lands on, and a local id from another namespace projects into the host's namespace, where it names an unrelated object.

### Why not named slots

A design with named slots, where a track said "Body" and the animator mapped "Body" to an object, was rejected:

- The reuse it offered is covered already. A timeline lives in its animator's file, so sharing across characters is the whole animator as a prefab, and prefab instances retarget on their own.
- Under an animator a track's own target was ignored, so a self-contained timeline did nothing until every slot was keyed and bound. Two free-text strings had to match, and a typo stayed invisible until runtime.
- The one thing only slots could do, one timeline playing into different objects across states, nobody needs. Duplicating the timeline covers it.

## The animator names no track kinds

A track kind in any plugin shows its binding field under the animator's states by naming that field on its `Track_Desc` (`binding_field`). The field's type and picker tags are read from the track's struct, so the row matches the track's own inspector.

## The TimelineAnimator's data

- The animator is a plain component, not an asset. Sharing a state set is putting the component in a prefab.
- `fade` is on the state rather than at the call site, so retuning how a switch feels is an inspector edit, not a code change.
- A state's timeline is a `Ref_Local`, a director in the same file. Sharing goes through prefabs, and the timelines travel inside them. If a timeline ever has to live in another asset, the field becomes an `engine.Ref` and the state's build gains an instantiate branch.

## Testing

`test_timeline_animator_demo_scene_loads` plays a state through to a moved transform. A test that only checks that the scene parses and the names resolve passes while the animator poses nothing, since the sample's clips are not in the test asset database. An assertion that the object moves is the one that cannot pass for the wrong reason.

## See also

- [Timelines as states](../guides/TimelineStates.md), the sample step by step.
- [Sequencer](/plugins/sequencer/docs/_index.md), the timeline system itself.
- [Roadmap](../Roadmap.md), for the open questions and known concerns of the TimelineAnimator.
