package sequencer_core

// The clip-tween vocabulary — the floor TWEEN PACKAGES build on
// (docs/Sequencer.md "Tweens"). A clip tween is a plain struct with a
// @(typ_guid), an embedded Clip_Tween base and one evaluate_<Name>(t) proc:
// PURE pose as a function of clip-normalized time, which is what makes the
// same tween exact under Play, scrubbing and the edit-mode preview alike.
// TweenUnion in the sequencer package names every variant and dispatches.
// Variant packages import THIS package, never the sequencer.
//
// This vocabulary is deliberately SEPARATE from packages/tween (the
// self-ticking graph tweens): the two may unify later, and the union +
// dispatch is the seam that keeps both directions open.

import "moonhug:engine"

// When a to-style tween's captured `from` refreshes. The capture's natural
// lifetime is the PERFORMANCE: .Play captures once per play session — kept
// across loop wraps, so a loop replays the identical motion — and .Enter
// re-captures on every span entry, so each loop pass continues from wherever
// the object is now (the relative-motion feel). Edit mode ignores both: the
// preview always shows the first pass, and preview end clears every capture.
Capture_Mode :: enum u8 {
	Play,
	Enter,
}

// Embedded at the top of every clip-tween variant. `captured` is runtime
// state: a to-style tween captures its `from` pose on the first evaluation
// and the flag marks that capture, so the track can restore (evaluate at 0)
// and clear it generically — on preview end, and per `capture` in Play.
Clip_Tween :: struct {
	capture:  Capture_Mode,
	captured: bool `json:"-" inspect:"-"`,
}

// What an evaluate proc sees. Deliberately small: a tween that needs more
// reads it off the world through these handles.
Tween_Ctx :: struct {
	owner:  engine.Transform_Handle, // the director's transform
	target: engine.Ref_Local,        // TweenTrack.target — the track's default subject
	clip:   engine.Transform_Handle, // the clip node the tween sits on
}
