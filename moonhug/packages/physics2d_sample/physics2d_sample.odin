package physics2d_sample

// Sample content for the physics2d package (docs/Plugins.md):
// assets/physics2d_sample.scene drops dynamic bodies onto a static ground
// and a tilted ramp, run_configs/run.odin plays it through the app runner
// (F3 in the app toggles collider wireframes). The package ships no code.

// Load-bearing: prebuild discovers packages by scanned DECLARATIONS — a file
// with only a package clause is invisible to it.
PHYSICS2D_SAMPLE :: true
