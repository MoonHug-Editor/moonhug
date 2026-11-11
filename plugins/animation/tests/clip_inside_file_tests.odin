package animation_tests

import "core:testing"
import "moonhug:editor/subassets"

// A clip loads from the animation importer's artifact, so it cannot be a
// sub-asset or an embedded asset: the picker of a clip field offers only
// files and the clips inside models.
@(test)
test_a_clip_cannot_live_inside_another_file :: proc(t: ^testing.T) {
	testing.expect(t, !subassets.can_live_inside("anim"), "the animation importer owns .anim")
}
