---
title: "rigging"
description: "Poses changed after animation: TwoBoneIK makes a limb reach a target, SpringBones makes a chain of bones swing"
tags: ["rigging", "plugin"]
---

The rigging plugin changes a pose after animation wrote it. TwoBoneIK bends an arm or a leg so the hand or the foot reaches a target. SpringBones lets a chain of bones lag behind and swing as its root moves. Both work on plain objects, so a skinned character's bones and a chain of cubes are the same to them.

## What it adds

**Components**

- [TwoBoneIK](components/TwoBoneIK.md) turns the two bones of a limb so its end reaches a target.
- [SpringBones](components/SpringBones.md) makes a chain of bones swing: hair, tails, capes, antennas.
- [SpringBoneCollider](components/SpringBoneCollider.md) is a sphere a spring chain stays out of.

## What it needs

- The engine plugin only. The animation plugin is not needed: the components read whatever pose the objects have. With animation, they run after it each frame.

## Quick start

Open `rigging_demo.scene` from the `rigging_sample` plugin and press Play. Each component is next to the same setup without it.

- **Two characters, a ball circling before each.** The right one has a TwoBoneIK on its right arm with the ball as the target: the hand follows the ball. The left one plays the same clip and ignores it. This is what IK is for: a hand on a door handle or a ledge, a foot on a step, a weapon held with both hands, with the animation left as it is.
- **Two chains on bars that slide past a sphere.** The right one has SpringBones with the sphere as its collider: it swings behind the bar and goes around the sphere. The left one is the same chain with nothing on it: stiff, and straight through the sphere. This is what spring bones are for: motion nobody animates by hand.

To try it on your own objects:

1. Add Rigging, TwoBoneIK to a character. Set `tip` to the hand and `target` to an object. Press Play and move the target.
2. Add Rigging, SpringBones to the first bone of a tail. Press Play and move the character.

## Behavior

- Both components run while the game runs, in the late update, after every update and after animation. TwoBoneIK runs first, so a spring chain on a limb follows the solved limb.
- They write the bones' rotations. Bone positions and lengths stay.
- In the editor a selected component draws its bones, target and colliders.

## Limits

- TwoBoneIK solves limbs of exactly two bones. There is no solver for longer chains, no foot placement on the ground and no look-at.
- SpringBones collides with spheres only, at the bones' ends. A long bone can pass through a small sphere between its ends.
- The spring motion depends on the frame rate: a chain tuned at 60 frames per second swings differently at 30.

## Reference

- [API reference](/docs/reference/packages/rigging/rigging.md) of the `rigging` package.
