package animation_sample

// Sample content for the Animation component (plugins/animation/docs/AnimationComponent.md) and
// SkinnedMeshRenderer:
// assets/animation_demo.scene is the essentials plugin's UAL1 character
// (meshes/characters/UAL1_Standard.glb) — a skinned mesh deformed by its
// armature, and an Animation component whose layer holds a Locomotion blend
// over walk and run plus Idle, Jump and Death, playing the model's own clips.
// animation_demo.odin plays those states by name and drives the blend.
//
// The scene holds the model's node hierarchy, as the engine's scene_from_gltf
// writes it, wrapped in a camera, a light and a floor.
//
// The sequencer and TimelineAnimator samples are the sibling timeline_sample
// package.

// Load-bearing: prebuild discovers packages by scanned DECLARATIONS — a file
// with only a package clause is invisible to it.
ANIMATION_SAMPLE :: true
