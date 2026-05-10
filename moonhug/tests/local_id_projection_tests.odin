package tests

import "../engine"
import "core:testing"

// Stage 1 tests for the Unity-style XOR projection used to encode deep
// override / Ref_Local targets without a serialized chain field.
//
// The projection composes a (PrefabInstance lid in outer namespace) with a
// (target lid in inner namespace) into a single derived lid. Inverting it
// (given the outer lid) recovers the inner. Repeated application chains
// across multiple nesting levels.
//
// Reference: Unity's stripped-object encoding combines fileIDs via XOR + mask
// to keep the result positive within an i64. See:
//   moonhug-editor/docs/NestedPrefabs.md (Stripped-object section)
// and Unity manual:
//   https://docs.unity3d.com/6000.6/Documentation/Manual/yaml-prefab-serialization.html

@(test)
test_local_id_project_roundtrip :: proc(t: ^testing.T) {
	outer := engine.Local_ID(1578938780440150505)
	inner := engine.Local_ID(3611875511678201262)
	derived := engine.local_id_project(outer, inner)
	recovered := engine.local_id_unproject(outer, derived)
	testing.expect_value(t, recovered, inner)
}

@(test)
test_local_id_project_self_inverse :: proc(t: ^testing.T) {
	// project(a, b) and project(b, a) should yield the same derived id since
	// XOR is symmetric. unproject is the same operation as project.
	a := engine.Local_ID(12345)
	b := engine.Local_ID(67890)
	testing.expect_value(t, engine.local_id_project(a, b), engine.local_id_project(b, a))
	testing.expect_value(t, engine.local_id_project(a, b), engine.local_id_unproject(a, b))
}

@(test)
test_local_id_project_chain :: proc(t: ^testing.T) {
	// Depth-3: a target lid in the deepest namespace projected through two
	// PrefabInstance lids (mid_in_outer, leaf_in_mid). Recovery must walk
	// inverse operations in the same order.
	mid_in_outer := engine.Local_ID(1578938780440150505)
	leaf_in_mid := engine.Local_ID(2866460459978038657)
	target_in_leaf := engine.Local_ID(3611875511678201262)

	step1 := engine.local_id_project(leaf_in_mid, target_in_leaf)
	derived := engine.local_id_project(mid_in_outer, step1)

	step1_back := engine.local_id_unproject(mid_in_outer, derived)
	target_back := engine.local_id_unproject(leaf_in_mid, step1_back)

	testing.expect_value(t, target_back, target_in_leaf)
}

@(test)
test_local_id_project_keeps_positive :: proc(t: ^testing.T) {
	// The mask in the projection guarantees the result fits in a positive
	// i64. Using two large values that, naïvely XORed, would set the sign
	// bit. The masked output must remain non-negative.
	a := engine.Local_ID(0x7FFFFFFFFFFFFFFF)
	b := engine.Local_ID(0x4000000000000000)
	result := engine.local_id_project(a, b)
	testing.expect(t, result >= 0, "projected lid must be non-negative")
}
