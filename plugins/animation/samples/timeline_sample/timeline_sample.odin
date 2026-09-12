package timeline_sample

// Sample content for the sequencer (docs/Sequencer.md):
// assets/timeline_demo.scene is a fireworks show driven by a PlayableDirector
// — a manual-start rocket system (Death sub emitter into spinning star
// sparks, comet trails) played by a particles track, plus an audio track.
// The timeline IS the director's subtree (track and clip nodes). Open the
// scene, select TimelineDemo and use the Sequencer window's Preview.
//
// assets/timeline_animator_demo.scene is the TimelineAnimator sample on top
// of the same pieces — see timeline_animator_demo.odin, the only code here.

// Load-bearing: prebuild discovers packages by scanned DECLARATIONS — a file
// with only a package clause is invisible to it.
TIMELINE_SAMPLE :: true
