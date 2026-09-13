package animation_sample

// Sample gameplay for the Animation component (docs/PlayableGraph.md).
//
// assets/animation_demo.scene is the imported character: a skinned mesh posed
// by SkinnedMeshRenderer, its armature, and an Animation component holding the
// nine clips that came with the model. This script sits next to that component
// and cross-fades between them from inspector buttons.
//
// The clips are FIELDS rather than names in code, so the scene decides which
// clip each button plays and the inspector can repoint one without a rebuild.

import "core:log"
import "moonhug:engine"
import anim "moonhug:packages/animation"

@(component={menu="Demo/AnimationDemo"})
@(typ_guid={guid = "b1d4c0ae-3f57-4a62-9d18-6c0e5a79f284"})
AnimationDemo :: struct {
	using base: engine.CompData `inspect:"-"`,

	// Cross-fade duration the buttons ask for, in seconds. 0 cuts.
	fade: f32,

	// What each button plays.
	idle:  engine.Asset_GUID `ext:"anim"`,
	walk:  engine.Asset_GUID `ext:"anim"`,
	run:   engine.Asset_GUID `ext:"anim"`,
	jump:  engine.Asset_GUID `ext:"anim"`,
	death: engine.Asset_GUID `ext:"anim"`,
}

reset_AnimationDemo :: proc(d: ^AnimationDemo) {
	d.fade = 0.25
}

// The Animation component this script drives. Both sit on the same object, the
// way a game puts its controller next to what it controls.
@(private = "file")
_ad_animation :: proc(d: ^AnimationDemo) -> ^anim.Animation {
	_, a := engine.transform_get_comp(d.owner, anim.Animation)
	return a
}

@(private = "file")
_ad_play :: proc(d: ^AnimationDemo, clip: engine.Asset_GUID, what: string) {
	a := _ad_animation(d)
	if a == nil {
		log.warn("[AnimationDemo] no Animation component on this object")
		return
	}
	if engine.asset_guid_is_empty(clip) {
		log.warnf("[AnimationDemo] the %s clip is unset", what)
		return
	}
	anim.animation_cross_fade(a, clip, d.fade)
}

@(inspector_button={label="Idle", row=0})
ad_idle :: proc(d: ^AnimationDemo) {
	_ad_play(d, d.idle, "idle")
}

@(inspector_button={label="Walk", row=0})
ad_walk :: proc(d: ^AnimationDemo) {
	_ad_play(d, d.walk, "walk")
}

@(inspector_button={label="Run", row=0})
ad_run :: proc(d: ^AnimationDemo) {
	_ad_play(d, d.run, "run")
}

@(inspector_button={label="Jump", row=-1})
ad_jump :: proc(d: ^AnimationDemo) {
	_ad_play(d, d.jump, "jump")
}

@(inspector_button={label="Death", row=-1})
ad_death :: proc(d: ^AnimationDemo) {
	_ad_play(d, d.death, "death")
}

@(inspector_button={label="Stop", row=-2})
ad_stop :: proc(d: ^AnimationDemo) {
	if a := _ad_animation(d); a != nil do anim.animation_stop(a)
}
