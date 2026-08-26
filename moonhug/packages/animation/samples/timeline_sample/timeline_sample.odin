package timeline_sample

// Sample content for the sequencer (docs/Sequencer.md):
// assets/timeline_demo.scene is a fireworks show driven by a PlayableDirector
// — a manual-start rocket system (Death sub emitter into spinning star
// sparks, comet trails) played by a particles control track on
// assets/fireworks.timeline. Open the scene, select TimelineDemo and use the
// Sequencer window's Preview. The package ships no code.

// Load-bearing: prebuild discovers packages by scanned DECLARATIONS — a file
// with only a package clause is invisible to it.
TIMELINE_SAMPLE :: true
