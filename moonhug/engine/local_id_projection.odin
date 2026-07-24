package engine

// Unity-style fileID projection used to encode deep references without a
// serialized chain field. Composing an outer PrefabInstance lid with a target
// lid in the inner namespace produces a single derived lid; the inverse with
// the same outer lid recovers the inner. Chaining yields Unity's depth-N
// behavior where override targets carry only `(immediate_prefab_guid,
// derived_lid)` and the chain is reconstructible from the live NS tree at
// resolve time.
//
// XOR is its own inverse, and the high-bit mask keeps the result positive so
// it round-trips through JSON's i64-shaped Local_ID without sign issues.
@(private)
LOCAL_ID_PROJECTION_MASK :: 0x7FFFFFFFFFFFFFFF

local_id_project :: proc(outer, inner: Local_ID) -> Local_ID {
	combined := i64(outer) ~ i64(inner)
	masked := combined & LOCAL_ID_PROJECTION_MASK
	return Local_ID(masked)
}

// Inverse of local_id_project given the same outer lid. Implemented via the
// same XOR+mask: project(a, project(a, b)) == b for any b that fits in the
// lower 63 bits, which is the case for all valid Local_IDs (authored lids are
// minted below 2^52 by scene_new_lid, composed instance lids sit below 2^53).
local_id_unproject :: proc(outer, derived: Local_ID) -> Local_ID {
	return local_id_project(outer, derived)
}
