package physics2d_sample

// Sample content for the physics2d package (docs/core/Plugins.md):
// assets/physics2d_sample.scene is a machine a marble goes around, one
// station per physics2d feature, and machine.odin holds the stations'
// scripts. run_configs/run.odin plays it through the app runner (F3 in the
// app toggles collider wireframes).
//
// The scene, its two physics materials and its sprites are generated: change
// the generator, not the files.

// Load-bearing: prebuild discovers packages by scanned DECLARATIONS — a file
// with only a package clause is invisible to it.
PHYSICS2D_SAMPLE :: true
