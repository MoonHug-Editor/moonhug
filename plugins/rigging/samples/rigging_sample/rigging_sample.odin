package rigging_sample

// Sample content for the rigging plugin (plugins/rigging/docs/_index.md).
// assets/rigging_demo.scene shows each component next to the same setup
// without it. Press Play to see them move.
//
// - Two idle characters, a ball circling in front of each. The right one
//   has a TwoBoneIK on its right arm with the ball as the target: its hand
//   follows the ball. The left one plays the same clip and ignores it.
// - Two chains hanging from bars that slide from side to side past a
//   sphere. The right one has SpringBones with the sphere as its collider:
//   it swings behind the bar and wraps around the sphere. The left one is
//   the same chain with nothing on it: stiff, and straight through the
//   sphere.
//
// rig_demo.odin holds the two small scripts the scene uses.

// Load-bearing: prebuild discovers packages by scanned DECLARATIONS — a file
// with only a package clause is invisible to it.
RIGGING_SAMPLE :: true
