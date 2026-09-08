package sequencer_core

// The script vocabulary — the floor SCRIPT PACKAGES build on
// (docs/Sequencer.md "Scripts"). A script is a plain struct with a
// @(typ_guid) and OPTIONAL lifecycle procs — enter_<Name>, tick_<Name>,
// exit_<Name> — called when playback crosses into its clip's span, every
// tick inside it, and when it leaves. ScriptUnion in the sequencer package
// names every variant and dispatches. Variant packages import THIS package,
// never the sequencer: the union sits above them, so first-party scripts
// (sequencer/scripts) and plugin scripts are structurally identical.

import "moonhug:engine"

// Embedded by every script variant: `using base: Clip_Script`. Empty — its
// job is to MARK the struct as a script so script_gen finds it. Prebuild is
// syntax-only (no type resolution), so a named base field is the signal a
// generator can see, the same way Clip_Tween marks clip tweens.
Clip_Script :: struct {}

// What a script's lifecycle procs see. Deliberately small: a script that
// needs more reads it off the world through these handles.
Script_Ctx :: struct {
	owner:  engine.Transform_Handle, // the director's transform
	target: engine.Ref_Local,        // TrackScript.target — the track's default subject
	clip:   engine.Transform_Handle, // the clip node the script sits on
	time:   f32,                     // director time at the call
}
