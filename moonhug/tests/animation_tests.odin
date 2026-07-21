package tests

// AnimationClip sampling + the legacy-style Animation component tick:
// clip JSON round-trip, keyframe interpolation (lerp/step/slerp), child-path
// targeting, and Once/Loop wrap behavior through animation_tick.

import cgltf "vendor:cgltf"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:os"
import "core:testing"
import "core:math"
import "../engine"
import "../app"
import common "common"

// A 1-second clip: owner position x 0→2, plus a child "Arm" scale snap
// (STEP) from 1 to 3 at t=0.5.
_make_test_clip :: proc(alloc := context.allocator) -> engine.AnimationClip {
	clip := engine.AnimationClip{length = 1, wrap = .Once}
	clip.channels = make([dynamic]engine.Animation_Channel, alloc)

	pos := engine.Animation_Channel{path = .Position}
	pos.times = make([dynamic]f32, alloc)
	pos.values = make([dynamic][4]f32, alloc)
	append(&pos.times, 0, 1)
	append(&pos.values, [4]f32{0, 0, 0, 0}, [4]f32{2, 0, 0, 0})
	append(&clip.channels, pos)

	arm := engine.Animation_Channel{path = .Scale, step = true}
	arm.target = "Arm"
	arm.times = make([dynamic]f32, alloc)
	arm.values = make([dynamic][4]f32, alloc)
	append(&arm.times, 0, 0.5)
	append(&arm.values, [4]f32{1, 1, 1, 0}, [4]f32{3, 3, 3, 0})
	append(&clip.channels, arm)
	return clip
}

@(test)
test_animation_clip_marshal_roundtrip :: proc(t: ^testing.T) {
	clip := _make_test_clip(context.temp_allocator)
	data, err := json.marshal(clip, {spec = .JSON}, context.temp_allocator)
	testing.expect(t, err == nil, "clip should marshal")

	loaded: engine.AnimationClip
	uerr := json.unmarshal(data, &loaded, .JSON, context.temp_allocator)
	testing.expect(t, uerr == nil, "clip should unmarshal")
	testing.expect(t, loaded.length == 1 && loaded.wrap == .Once, "clip header should round-trip")
	testing.expect(t, len(loaded.channels) == 2, "channels should round-trip")
	if len(loaded.channels) == 2 {
		testing.expect(t, loaded.channels[1].target == "Arm", "channel target should round-trip")
		testing.expect(t, loaded.channels[1].step, "step flag should round-trip")
	}
}

@(test)
test_animation_component_tick :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	app.register_packages()

	engine.animation_clip_cache_init()
	defer engine.animation_clip_cache_shutdown()

	guid_id, _ := uuid.read("aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")
	guid := engine.Asset_GUID(guid_id)
	engine.animation_clip_cache[guid] = _make_test_clip()

	owner := engine.transform_new("Robot")
	child := engine.transform_new("Arm", owner)
	ct := engine.pool_get(&tc.world.transforms, engine.Handle(child))
	ct.scale = {1, 1, 1}

	_, a_ptr := engine.transform_add_comp(owner, .Animation)
	a := cast(^engine.Animation)a_ptr
	a.enabled = true
	a.clip = guid
	a.play_automatically = true
	a.speed = 1

	// Half the clip: position lerps to x=1, the child's STEP scale snaps to 3.
	engine.animation_tick(0.5)
	ot := engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	ct = engine.pool_get(&tc.world.transforms, engine.Handle(child))
	testing.expect(t, abs(ot.position.x - 1) < 0.001, "position should lerp to the midpoint")
	testing.expect(t, ct.scale.x == 3, "STEP channel should hold the second key at t=0.5")

	// Past the end with wrap Once: clamps to the last key and stops.
	engine.animation_tick(1.0)
	ot = engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	testing.expect(t, abs(ot.position.x - 2) < 0.001, "Once should clamp at the final key")
	testing.expect(t, !a.playing, "Once should stop at the clip end")

	// Loop override: restart, run 1.25s total → wrapped t=0.25 → x=0.5.
	a.wrap_mode = .Loop
	engine.animation_play(a)
	engine.animation_tick(1.25)
	ot = engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	testing.expect(t, abs(ot.position.x - 0.5) < 0.001, "Loop should wrap the play time")
	testing.expect(t, a.playing, "Loop should keep playing")

	_ = math.PI
}

// glTF → clip conversion on a fixture with a translation + rotation channel
// targeting the child node "Cube" under "Root".
@(test)
test_animation_clip_from_gltf :: proc(t: ^testing.T) {
	opts := cgltf.options{}
	data, res := cgltf.parse_file(opts, "moonhug/tests/fixtures/animated_cube.gltf")
	testing.expect(t, res == .success, "fixture should parse")
	if res != .success do return
	defer cgltf.free(data)
	lres := cgltf.load_buffers(opts, data, "moonhug/tests/fixtures/animated_cube.gltf")
	testing.expect(t, lres == .success, "fixture buffers should load")
	if lres != .success do return
	testing.expect(t, len(data.animations) == 1, "fixture should have one animation")
	if len(data.animations) != 1 do return

	clip, ok := engine.animation_clip_from_gltf(data, &data.animations[0])
	testing.expect(t, ok, "conversion should produce channels")
	testing.expect(t, clip.length == 1, "length should come from the last key")
	testing.expect(t, len(clip.channels) == 2, "both TRS channels should convert")
	if len(clip.channels) != 2 do return

	pos := clip.channels[0]
	testing.expect(t, pos.target == "Root/Cube", "target should be the node name path")
	testing.expect(t, pos.path == .Position, "first channel should be position")
	testing.expect(t, len(pos.times) == 2 && pos.values[1] == [4]f32{2, 0, 0, 0}, "position keys should unpack")

	rot := clip.channels[1]
	testing.expect(t, rot.path == .Rotation, "second channel should be rotation")
	testing.expect(t, abs(rot.values[1].z - 0.7071) < 0.001 && abs(rot.values[1].w - 0.7071) < 0.001,
		"rotation quat should unpack xyzw")
}

// Scene extraction: the .scene mirrors the glTF node hierarchy and the root
// carries the wired MeshFilter/MeshRenderer/Animation references.
@(test)
test_scene_from_gltf :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	app.register_packages()

	opts := cgltf.options{}
	data, res := cgltf.parse_file(opts, "moonhug/tests/fixtures/animated_cube.gltf")
	testing.expect(t, res == .success, "fixture should parse")
	if res != .success do return
	defer cgltf.free(data)

	mesh_id, _ := uuid.read("11111111-2222-3333-4444-555555555555")
	clip_id, _ := uuid.read("66666666-7777-8888-9999-aaaaaaaaaaaa")
	mesh_guid := engine.Asset_GUID(mesh_id)
	clip_guid := engine.Asset_GUID(clip_id)

	out :: "moonhug/tests/fixtures/_test_extracted_model.scene"
	defer os.remove(out)
	ok := engine.scene_from_gltf(data, "AnimatedCube", mesh_guid, {}, clip_guid, out)
	testing.expect(t, ok, "scene_from_gltf should save")
	if !ok do return

	s := engine.scene_load_single_path(out)
	testing.expect(t, s != nil, "extracted scene should load")
	if s == nil do return

	w := engine.ctx_world()
	root := engine.pool_get(&w.transforms, s.root.handle)
	testing.expect(t, root.name == "AnimatedCube", "root should be named after the model")

	// Node hierarchy: Root under the scene root, Cube under Root.
	cube: engine.Transform_Handle
	for child in root.children {
		ct := engine.pool_get(&w.transforms, child.handle)
		if ct == nil || ct.name != "Root" do continue
		for gc in ct.children {
			gt := engine.pool_get(&w.transforms, gc.handle)
			if gt != nil && gt.name == "Cube" do cube = engine.Transform_Handle(gc.handle)
		}
	}
	testing.expect(t, cube != {}, "node hierarchy Root/Cube should exist")
	if cube == {} do return

	// Mesh components live on the MESH NODE, wired to its part; the root only
	// carries the Animation.
	_, mf := engine.transform_get_comp(cube, engine.MeshFilter)
	testing.expect(t, mf != nil && mf.mesh == mesh_guid, "Cube should reference the model")
	if mf != nil do testing.expect_value(t, mf.part, i32(1))
	_, mr := engine.transform_get_comp(cube, engine.MeshRenderer)
	testing.expect(t, mr != nil && len(mr.materials) == 1, "Cube should have one material slot")
	_, root_mf := engine.transform_get_comp(engine.Transform_Handle(s.root.handle), engine.MeshFilter)
	testing.expect(t, root_mf == nil, "root should not draw the whole model on top of the parts")
	_, a := engine.transform_get_comp(engine.Transform_Handle(s.root.handle), engine.Animation)
	testing.expect(t, a != nil && a.clip == clip_guid, "Animation should reference the first clip")
	if a != nil do testing.expect(t, a.play_automatically, "Animation should default to play automatically")
}
