---
title: "Scripts and tweens"
description: "The script and tween variants a clip holds: the unions, the built-ins, and how a plugin adds a variant"
weight: 30
tags: ["sequencer", "concepts"]
---

A [ClipScript](../components/ClipScript/_index.md) holds a list of scripts and a [ClipTween](../components/ClipTween/_index.md) a list of tweens. Each element is one variant of a union, `ScriptUnion` or `TweenUnion`, and the prebuild generates both unions from the variants it finds.

## A script

A script is a `@(typ_guid)` struct that embeds `Clip_Script`, with any of four procs in the same file, all optional:

```odin
import "moonhug:packages/engine"
import core "moonhug:packages/sequencer/core"

@(typ_guid={guid = "..."})
ScriptShake :: struct {
	using base: core.Clip_Script `inline:""`,
	target:   engine.Ref_Local `ref:"Transform"`,
	strength: f32,
}

enter_ScriptShake :: proc(s: ^ScriptShake, ctx: ^core.Script_Ctx) { ... } // playback enters the span
tick_ScriptShake  :: proc(s: ^ScriptShake, ctx: ^core.Script_Ctx) { ... } // every frame inside it
exit_ScriptShake  :: proc(s: ^ScriptShake, ctx: ^core.Script_Ctx) { ... } // playback leaves it
type_cleanup_ScriptShake :: proc(s: ^ScriptShake) { ... }                 // it owns memory
```

`Script_Ctx` holds the director's object, the track's `target`, the clip object and the director's time. A script runs in play mode only.

## A tween

A tween is a `@(typ_guid)` struct that embeds `Clip_Tween`, with an `evaluate_<Name>(self, t, ctx)` proc in the same file. `t` runs from 0 at the clip's start to 1 at its end, and the proc sets the pose for that `t` and nothing else, which is what makes scrubbing exact. A tween that moves to a value captures its start the first time it evaluates and sets the base's `captured`. `Clip_Tween.capture` decides when the start is taken again ([TrackTween](../components/TrackTween.md)). `Tween_Ctx` holds the director's object, the track's `target` and the clip object.

## Adding a variant

1. Put the struct and its procs in a package that imports `moonhug:packages/sequencer/core`, never the sequencer itself. A variant that poses another plugin's component lives in that plugin's `sequencer` integration subpackage, so the plugin builds without the sequencer.
2. Run the prebuild. It finds the variant by its embedded base and its procs by name, and adds it to the union.

There is no registration call and no edit to the sequencer. The prebuild reads syntax only, so the base field is matched by its written type name and the procs must be in the struct's own file.

## The built-ins

Each built-in has a page under its component: the scripts ScriptSetActive and ScriptLog under [ClipScript](../components/ClipScript/_index.md), and the tweens under [ClipTween](../components/ClipTween/_index.md): TweenMoveLocalFromTo, TweenMoveLocalTo, TweenScaleLocalTo and TweenRotateLocalTo. ScriptNone and TweenNone do nothing: a new list element holds one until a type is picked. Each tween poses its own `target`, or the track's when its own is not set. Other plugins add variants: the sprites plugin's TweenFadeTo fades a SpriteRenderer.

Names go from the general to the specific, `Tween<Aspect><Space><Detail>`. The `@(typ_guid)` name space is global, so a name must not collide with the tween plugin's node types.

## Why the unions are built this way

- **Generated, exhaustive dispatch.** Each phase dispatches with a switch over every variant, generated into `script_union_generated.odin` and `tween_union_generated.odin`. A variant without a proc for a phase gets an empty case, so nothing is written by hand and nothing is forgotten.
- **Variants below the union.** First-party and plugin variants have the same shape: both import `sequencer/core`, and only the generated union names them.
- **Saved by guid.** Union tags are positions and shift when a variant is added, so the saved form carries the variant's type guid. `Ref_Local` fields inside a variant rebind on load like any component field.
- **An inert zero variant.** Both unions are `#no_nil` with ScriptNone and TweenNone first. A nil union saves as `null`, which does not load back: the whole component would then load as an unknown one, showing "Missing Component" with its list gone. The zero variant has its own `@(typ_guid)`, since the guid-keyed saving needs one.
- **Separate from the tween plugin.** These tweens are poses of a playhead inside a clip. The tween plugin's tweens run on their own clock. Neither imports the other, and the timeline is the container: a clip holds parallel tweens, consecutive clips are a sequence.

## Loop seams

At a loop's seam the modes differ in who owns the pose. In the editor the timeline owns it everywhere, so the object shows its start pose from the wrap on. In play mode the game owns an object outside the spans, so it holds the previous pass's end pose until the clip begins. Both follow from the same rule.

## See also

- [Playback](Playback.md)
