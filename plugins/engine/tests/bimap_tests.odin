package engine_tests

// core.Bimap: the two maps mirror each other through a re-insert, and has
// answers for a key and for a value.

import "core:testing"
import core "moonhug:libs/core"

@(test)
test_bimap_reinsert_keeps_the_maps_in_step :: proc(t: ^testing.T) {
	b: core.Bimap(int, string)
	defer core.cleanup_Bimap(&b)

	core.bimap_insert(&b, 1, "a")
	testing.expect(t, core.bimap_has(&b, 1) && core.bimap_has(&b, "a"), "has by key and by value")
	testing.expect(t, !core.bimap_has(&b, 2) && !core.bimap_has(&b, "b"), "has of what is not in")

	// The key gets another value: the old value is no longer paired.
	core.bimap_insert(&b, 1, "b")
	_, old := core.bimap_get(&b, "a")
	testing.expect(t, !old, "the replaced value is gone")
	// Removing by the old value must not take the live pair.
	testing.expect(t, !core.bimap_remove_by_val(&b, "a"), "nothing to remove by the old value")
	v, ok := core.bimap_get(&b, 1)
	testing.expect(t, ok && v == "b", "the live pair is still there")

	// The value gets another key: the old key is no longer paired.
	core.bimap_insert(&b, 2, "b")
	_, stale := core.bimap_get(&b, 1)
	testing.expect(t, !stale, "the replaced key is gone")
	testing.expect_value(t, len(b.forward), 1)
	testing.expect_value(t, len(b.backward), 1)
}
