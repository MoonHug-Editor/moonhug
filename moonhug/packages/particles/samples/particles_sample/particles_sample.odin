package particles_sample

// Sample content for the particles package (docs/Plugins.md):
// assets/particles_museum.scene is a museum scene — one exhibit per feature
// (fountain, burst, smoke, snow), each a ParticleSystem showing a different
// shape/space/over-lifetime setup. run_configs/run.odin plays it through the
// app runner. The package ships no code.

// Load-bearing: prebuild discovers packages by scanned DECLARATIONS — a file
// with only a package clause is invisible to it.
PARTICLES_SAMPLE :: true
