package prefabs_example

// A test-bed package: its assets/ holds an editable prefab/variant chain
// (c -> c_Variant -> blobs -> blobs_Variant -> host), meant to be opened and
// edited in the editor. Its tests/ runs INVARIANT tests (byte-stable
// roundtrip, no spurious override capture, variant edit propagation, deep
// overrides) against a copy of that chain with its own guids,
// moonhug/tests/fixtures/prefab_chain, so editing the example breaks no test.
// The tests derive expectations from the files rather than hardcoding
// authored values: a chain edited in the editor can be copied over the
// fixture (with the fixture's guids kept) to test it.
//
// No runtime code: this file exists because presence in packages/ compiles
// the package root into the binaries, and an empty folder is not an Odin
// package. The constant is load-bearing — prebuild discovers packages through
// their scanned DECLARATIONS, so a file with none leaves the package (and its
// tests/) out of the generated imports.
PREFABS_EXAMPLE :: true
