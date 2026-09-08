package animation_tests

// Property channels (clip_property.odin): AnimationClip channels that animate
// component fields by (component type guid, dotted field path) — Unity's
// EditorCurveBinding model. Camera is the target: fov (f32), clear_color
// ([4]f32), order (i32, discrete) cover the kind matrix on one engine
// component.

import "core:encoding/json"
import "core:encoding/uuid"
import "core:strings"
import "core:testing"
import "moonhug:engine"
import anim "moonhug:packages/animation"
import common "moonhug:tests/common"

// A constant single-key property clip: `component.field` = `value`.
_prop_clip :: proc(component: string, field: string, value: [4]f32, length: f32 = 1) -> anim.AnimationClip {
	clip := anim.AnimationClip{length = length, wrap = .Loop}
	clip.channels = make([dynamic]anim.Animation_Channel)
	ch := anim.Animation_Channel{
		component = strings.clone(component),
		field     = strings.clone(field),
	}
	ch.times = make([dynamic]f32)
	ch.values = make([dynamic][4]f32)
	append(&ch.times, 0)
	append(&ch.values, value)
	append(&clip.channels, ch)
	return clip
}

_camera_guid_str :: proc() -> string {
	return uuid.to_string(engine.get_guid_by_typeid(engine.Camera), context.temp_allocator)
}

_Prop_Test :: struct {
	tc:     ^common.TestCtx,
	owner:  engine.Transform_Handle,
	camera: ^engine.Camera,
	g:      anim.Playable_Graph,
	b:      anim.Animation_Binding,
}

_prop_setup :: proc(pt: ^_Prop_Test) {
	pt.tc = new(common.TestCtx)
	common.setup(pt.tc)
	context.user_ptr = &pt.tc.uc
	anim.animation_clip_cache_init()
	pt.owner = engine.transform_new("Rig")
	_, raw := engine.transform_add_comp(pt.owner, .Camera)
	pt.camera = cast(^engine.Camera)raw
	anim.playable_graph_init(&pt.g)
	anim.animation_binding_init(&pt.b, pt.owner)
}

_prop_teardown :: proc(pt: ^_Prop_Test) {
	anim.animation_binding_destroy(&pt.b)
	anim.playable_graph_destroy(&pt.g)
	anim.animation_clip_cache_shutdown()
	common.teardown(pt.tc)
	free(pt.tc)
}

@(test)
test_property_channel_f32_mix :: proc(t: ^testing.T) {
	pt: _Prop_Test
	_prop_setup(&pt)
	context.user_ptr = &pt.tc.uc
	defer _prop_teardown(&pt)

	cam := _camera_guid_str()
	a_guid, b_guid := _clip_guid(0x61), _clip_guid(0x62)
	anim.animation_clip_cache[a_guid] = _prop_clip(cam, "fov", {30, 0, 0, 0})
	anim.animation_clip_cache[b_guid] = _prop_clip(cam, "fov", {90, 0, 0, 0})

	mixer := anim.playable_add(&pt.g, anim.Mixer_Playable{})
	pt.g.root = mixer
	anim.playable_connect(&pt.g, mixer, anim.playable_add(&pt.g, anim.Clip_Playable{clip = a_guid}), 0.5)
	anim.playable_connect(&pt.g, mixer, anim.playable_add(&pt.g, anim.Clip_Playable{clip = b_guid}), 0.5)

	pose := anim.playable_graph_evaluate(&pt.g, &pt.b)
	anim.animation_pose_apply(&pt.b, pose)
	testing.expect(t, abs(pt.camera.fov - 60) < 0.001, "50/50 mix of fov 30 and 90 should land at 60")
}

@(test)
test_property_channel_vec4_full :: proc(t: ^testing.T) {
	pt: _Prop_Test
	_prop_setup(&pt)
	context.user_ptr = &pt.tc.uc
	defer _prop_teardown(&pt)

	guid := _clip_guid(0x63)
	anim.animation_clip_cache[guid] = _prop_clip(_camera_guid_str(), "clear_color", {1, 0, 0, 1})
	pt.g.root = anim.playable_add(&pt.g, anim.Clip_Playable{clip = guid})

	pose := anim.playable_graph_evaluate(&pt.g, &pt.b)
	anim.animation_pose_apply(&pt.b, pose)
	testing.expect(t, pt.camera.clear_color == {1, 0, 0, 1}, "full-weight vec4 channel writes the whole value")
}

@(test)
test_property_channel_discrete_dominant :: proc(t: ^testing.T) {
	pt: _Prop_Test
	_prop_setup(&pt)
	context.user_ptr = &pt.tc.uc
	defer _prop_teardown(&pt)

	cam := _camera_guid_str()
	a_guid, b_guid := _clip_guid(0x64), _clip_guid(0x65)
	anim.animation_clip_cache[a_guid] = _prop_clip(cam, "order", {5, 0, 0, 0})
	anim.animation_clip_cache[b_guid] = _prop_clip(cam, "order", {9, 0, 0, 0})

	mixer := anim.playable_add(&pt.g, anim.Mixer_Playable{})
	pt.g.root = mixer
	a_node := anim.playable_add(&pt.g, anim.Clip_Playable{clip = a_guid})
	anim.playable_connect(&pt.g, mixer, a_node, 0.3)
	anim.playable_connect(&pt.g, mixer, anim.playable_add(&pt.g, anim.Clip_Playable{clip = b_guid}), 0.7)

	pose := anim.playable_graph_evaluate(&pt.g, &pt.b)
	anim.animation_pose_apply(&pt.b, pose)
	testing.expect(t, pt.camera.order == 9, "discrete channels take the dominant contributor, never a lerp")

	// A lone clip below half weight loses to the default.
	anim.playable_remove(&pt.g, pt.g.root)
	pt.g.root = {}
	mixer2 := anim.playable_add(&pt.g, anim.Mixer_Playable{})
	pt.g.root = mixer2
	anim.playable_connect(&pt.g, mixer2, a_node, 0.3)
	pose2 := anim.playable_graph_evaluate(&pt.g, &pt.b)
	anim.animation_pose_apply(&pt.b, pose2)
	testing.expect(t, pt.camera.order == 0, "a discrete channel below half weight rests at the default")
}

@(test)
test_property_channel_partial_weight_blends_default :: proc(t: ^testing.T) {
	pt: _Prop_Test
	_prop_setup(&pt)
	context.user_ptr = &pt.tc.uc
	defer _prop_teardown(&pt)

	guid := _clip_guid(0x66)
	anim.animation_clip_cache[guid] = _prop_clip(_camera_guid_str(), "fov", {100, 0, 0, 0})
	mixer := anim.playable_add(&pt.g, anim.Mixer_Playable{})
	pt.g.root = mixer
	anim.playable_connect(&pt.g, mixer, anim.playable_add(&pt.g, anim.Clip_Playable{clip = guid}), 0.25)

	// Bind-time default fov is 60 (reset_Camera): 0.25*100 + 0.75*60 = 70.
	pose := anim.playable_graph_evaluate(&pt.g, &pt.b)
	anim.animation_pose_apply(&pt.b, pose)
	testing.expect(t, abs(pt.camera.fov - 70) < 0.001, "partial weight blends toward the bind-time default")
}

@(test)
test_property_channel_unresolved_skips :: proc(t: ^testing.T) {
	pt: _Prop_Test
	_prop_setup(&pt)
	context.user_ptr = &pt.tc.uc
	defer _prop_teardown(&pt)

	a_guid, b_guid := _clip_guid(0x67), _clip_guid(0x68)
	anim.animation_clip_cache[a_guid] = _prop_clip(_camera_guid_str(), "no_such_field", {1, 0, 0, 0})
	anim.animation_clip_cache[b_guid] = _prop_clip("not-a-guid", "fov", {1, 0, 0, 0})
	mixer := anim.playable_add(&pt.g, anim.Mixer_Playable{})
	pt.g.root = mixer
	anim.playable_connect(&pt.g, mixer, anim.playable_add(&pt.g, anim.Clip_Playable{clip = a_guid}), 1)
	anim.playable_connect(&pt.g, mixer, anim.playable_add(&pt.g, anim.Clip_Playable{clip = b_guid}), 1)

	before := pt.camera^
	pose := anim.playable_graph_evaluate(&pt.g, &pt.b)
	anim.animation_pose_apply(&pt.b, pose)
	testing.expect(t, pt.camera.fov == before.fov, "unresolvable channels are skipped, nothing written")
}

@(test)
test_property_channel_write_defaults_restores :: proc(t: ^testing.T) {
	pt: _Prop_Test
	_prop_setup(&pt)
	context.user_ptr = &pt.tc.uc
	defer _prop_teardown(&pt)

	guid := _clip_guid(0x69)
	anim.animation_clip_cache[guid] = _prop_clip(_camera_guid_str(), "fov", {100, 0, 0, 0})
	pt.g.root = anim.playable_add(&pt.g, anim.Clip_Playable{clip = guid})

	original := pt.camera.fov
	pose := anim.playable_graph_evaluate(&pt.g, &pt.b)
	anim.animation_pose_apply(&pt.b, pose)
	testing.expect(t, abs(pt.camera.fov - 100) < 0.001, "the clip drives the field")

	anim.animation_binding_write_defaults(&pt.b)
	testing.expect(t, pt.camera.fov == original, "write_defaults restores the bind-time value")
}

@(test)
test_property_channel_direct_apply :: proc(t: ^testing.T) {
	pt: _Prop_Test
	_prop_setup(&pt)
	context.user_ptr = &pt.tc.uc
	defer _prop_teardown(&pt)

	clip := _prop_clip(_camera_guid_str(), "fov", {42, 0, 0, 0})
	defer anim._animation_clip_destroy(&clip)
	anim.animation_clip_apply(&clip, pt.owner, 0)
	testing.expect(t, abs(pt.camera.fov - 42) < 0.001, "the legacy direct apply path honors property channels")
}

@(test)
test_property_channel_json_round_trip :: proc(t: ^testing.T) {
	pt: _Prop_Test
	_prop_setup(&pt)
	context.user_ptr = &pt.tc.uc
	defer _prop_teardown(&pt)

	clip := _prop_clip(_camera_guid_str(), "clear_color", {0, 1, 0, 1})
	defer anim._animation_clip_destroy(&clip)

	data, merr := json.marshal(clip, {}, context.temp_allocator)
	testing.expect(t, merr == nil, "clip marshals")

	loaded: anim.AnimationClip
	uerr := json.unmarshal(data, &loaded, .JSON, context.allocator)
	defer anim._animation_clip_destroy(&loaded)
	testing.expect(t, uerr == nil, "clip unmarshals")
	testing.expect(t, len(loaded.channels) == 1, "channel survives")
	testing.expect(t, loaded.channels[0].component == clip.channels[0].component, "component guid round-trips")
	testing.expect(t, loaded.channels[0].field == "clear_color", "field path round-trips")
}
