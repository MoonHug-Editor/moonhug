package sequencer

// Timeline-as-prefab (docs/Sequencer.md): a timeline is a TRANSFORM SUBTREE,
// not a parallel document format. The director's transform holds track nodes
// as children; each track node holds clip nodes. Everything the prefab
// system does — nesting, variants, overrides, lids, undo, pickers — applies
// to timelines because they are ordinary scene content.
//
// Node names carry track and clip names. Track order is sibling order; clip
// order derives from start times.

import "moonhug:engine"

// One track: a child node of a PlayableDirector's transform. `kind` is the
// Track_Desc registry key; `target` is what the track drives — authored in
// the timeline prefab or set per instance as a prefab OVERRIDE (this is the
// whole exposure story: overrides are the tweak surface).
@(component)
@(typ_guid={guid = "9666aed8-e855-4a36-90fa-4adbbd5db3c0"})
TimelineTrack :: struct {
	using base: engine.CompData `inspect:"-"`,

	kind:   string,
	muted:  bool,
	target: engine.Ref_Local,
}

cleanup_TimelineTrack :: proc(t: ^TimelineTrack) {
	delete(t.kind)
}

// One clip: a child node of a track node. The node's NAME is the clip name
// (markers fire it, blocks label with it).
@(component)
@(typ_guid={guid = "2f5aa77a-01a4-4265-80cd-1c5f136b9efd"})
TimelineClip :: struct {
	using base: engine.CompData `inspect:"-"`,

	start:    f32,
	duration: f32,
	ease_in:  f32, // seconds of weight ramp at the clip's start
	ease_out: f32, // seconds of weight ramp at the clip's end
	speed:    f32, // clip-local time scale, 0 behaves as 1
	asset:    engine.Asset_GUID,
}
