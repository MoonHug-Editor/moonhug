package prefabs_example

// A test-bed package: its assets/ holds an editable prefab/variant chain
// (c -> c_Variant -> bullet -> bullet_Variant -> host) and its tests/ runs
// INVARIANT tests against those committed files — byte-stable roundtrip,
// no spurious override capture, variant edit propagation, deep overrides.
//
// The scenes are meant to be opened and edited in the editor. The tests
// derive expectations from the files rather than hardcoding authored values,
// so editing keeps them meaningful — they fail only when an edit removes the
// STRUCTURE a test exercises (e.g. deleting the variant's deep override).
//
// No runtime code: this file exists because presence in packages/ compiles
// the package root into the binaries, and an empty folder is not an Odin
// package. The constant is load-bearing — prebuild discovers packages through
// their scanned DECLARATIONS, so a file with none leaves the package (and its
// tests/) out of the generated imports.
PREFABS_EXAMPLE :: true
