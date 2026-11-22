package mhgui_animation_tests

// The Animation transition of a Selectable (mhgui/animation): a change of
// state plays the Animation state of the same name on the target node.

import "core:strings"
import "core:testing"
import "moonhug:packages/engine"
import anim "moonhug:packages/animation"
import mhgui "moonhug:packages/mhgui"
import mhgui_anim "moonhug:packages/mhgui/animation"
import common "moonhug:tests/common"

@(test)
test_selectable_animation_plays_the_state :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	node := engine.transform_new("Button")
	_, raw := engine.transform_add_comp(node, .Button)
	b := cast(^mhgui.Button)raw
	b.enabled = true
	mhgui.type_reset_Button(b)
	b.transition = .Animation
	_, araw := engine.transform_add_comp(node, .Animation)
	a := cast(^anim.Animation)araw
	a.enabled = true
	defer engine.type_cleanup(.Animation, araw)
	// States with a guid for a clip: enough for a state to play, no clip loads.
	clip :: proc(n: u8) -> anim.Animation_Entry_Kind {
		g: engine.Asset_GUID
		g[0] = n
		return anim.Animation_Entry_Clip{clip = engine.PPtr{guid = g}}
	}
	a.layers = make([dynamic]anim.Animation_Layer)
	entries := make([dynamic]anim.Animation_Entry)
	append(&entries, anim.Animation_Entry{id = 1, name = strings.clone("Normal"), kind = clip(1)})
	append(&entries, anim.Animation_Entry{id = 2, name = strings.clone("Highlighted"), kind = clip(2)})
	append(&a.layers, anim.Animation_Layer{entries = entries})

	testing.expect(t, !a.playing, "nothing plays before the first tick")
	b.state = .Highlighted
	mhgui_anim.selectable_animation_tick(0)
	testing.expect(t, a.playing, "the state's Animation state plays")
	testing.expect_value(t, b.shown, u8(mhgui.Selectable_State.Highlighted) + 1)

	// The same state again asks for nothing: a stopped Animation stays stopped.
	anim.animation_stop(a)
	mhgui_anim.selectable_animation_tick(0)
	testing.expect(t, !a.playing, "no change of state, nothing played again")
	b.state = .Normal
	mhgui_anim.selectable_animation_tick(0)
	testing.expect(t, a.playing, "a change of state plays the new one")

	// A state the Animation has no entry for plays nothing, and is not asked again.
	anim.animation_stop(a)
	b.state = .Pressed
	mhgui_anim.selectable_animation_tick(0)
	testing.expect(t, !a.playing, "no state named Pressed: nothing plays")
	testing.expect_value(t, b.shown, u8(mhgui.Selectable_State.Pressed) + 1)

	// Another transition leaves the Animation alone.
	b.transition = .Color_Tint
	b.state = .Normal
	mhgui_anim.selectable_animation_tick(0)
	testing.expect(t, !a.playing, "Color_Tint does not touch the Animation")
}
