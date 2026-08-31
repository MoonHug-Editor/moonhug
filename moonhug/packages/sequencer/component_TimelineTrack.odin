package sequencer

// Timeline-as-prefab (docs/Sequencer.md): a timeline is a TRANSFORM SUBTREE.
// The director's node holds track nodes as children; each track node holds
// clip nodes. Everything the prefab system does — nesting, variants,
// overrides, lids, undo, pickers — applies to timelines because they are
// ordinary scene content.
//
// A track node carries TWO components: TimelineTrack (what every track has)
// and its KIND component (TrackAudio, TrackParticles, ...), which is the
// discriminator — the registry keys on its TypeKey. Kind components own
// their own targets and options, so a `ref:` tag drives the picker and no
// shared field has to mean different things per kind. Same split for clips:
// TimelineClip holds the span, the kind's clip component holds its payload.
//
// Node names carry track and clip names. Track order is sibling order; clip
// order derives from start times.

import "moonhug:engine"

// The universal half of a track: everything a timeline needs regardless of
// what the track drives.
@(component)
@(typ_guid={guid = "9666aed8-e855-4a36-90fa-4adbbd5db3c0"})
TimelineTrack :: struct {
	using base: engine.CompData `inspect:"-"`,

	muted: bool,
}

// The universal half of a clip: its span on the timeline. The kind's clip
// component (ClipAudio, ClipAnimation, ...) carries the payload.
@(component)
@(typ_guid={guid = "2f5aa77a-01a4-4265-80cd-1c5f136b9efd"})
TimelineClip :: struct {
	using base: engine.CompData `inspect:"-"`,

	start:    f32,
	duration: f32,
	ease_in:  f32, // seconds of weight ramp at the clip's start
	ease_out: f32, // seconds of weight ramp at the clip's end
	speed:    f32, // clip-local time scale, 0 behaves as 1
}
