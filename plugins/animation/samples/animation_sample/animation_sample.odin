package animation_sample

// Sample content for the Animation component (docs/AnimationComponent.md) and
// SkinnedMeshRenderer:
// assets/animation_demo.scene is an imported glTF character — a skinned mesh
// deformed by its armature, and an Animation component whose layer holds a
// Locomotion blend over walk and run plus Idle, Jump and Death.
// animation_demo.odin plays those states by name and drives the blend.
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
