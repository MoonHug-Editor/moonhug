package animation_sample

// Sample content for the Animation component and SkinnedMeshRenderer:
// assets/animation_demo.scene is an imported glTF character — a skinned mesh
// deformed by its armature, an Animation component holding the nine clips the
// model ships with, and animation_demo.odin cross-fading between them from
// inspector buttons.
//
// assets/character/ is the import itself: the .gltf and its buffer, the
// material, the extracted clips, and Character3D.scene — the hierarchy the
// importer produces, which the demo scene wraps in a camera and a light.
//
// The sequencer and TimelineAnimator samples are the sibling timeline_sample
// package.

// Load-bearing: prebuild discovers packages by scanned DECLARATIONS — a file
// with only a package clause is invisible to it.
ANIMATION_SAMPLE :: true
