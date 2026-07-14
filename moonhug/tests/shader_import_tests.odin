package tests

// User shader importer tests (docs/Materials.md). The compile tests need the
// optional toolchain (glslc + spirv-cross) and self-skip when it's absent —
// artifact parsing is covered toolchain-free.

import "core:os"
import "core:testing"
import "../engine"

_toolchain_available :: proc() -> bool {
	state, _, _, err := os.process_exec({command = []string{"glslc", "--version"}}, context.temp_allocator)
	if err != nil do return false
	if !state.exited || state.exit_code != 0 do return false
	state, _, _, err = os.process_exec({command = []string{"spirv-cross", "--help"}}, context.temp_allocator)
	return err == nil
}

@(test)
test_shader_import_compiles_fixture :: proc(t: ^testing.T) {
	if !_toolchain_available() {
		testing.expect(t, true) // toolchain is an optional dependency
		return
	}

	artifact := "moonhug/tests/fixtures/shaders/_test_shader_artifact.bin"
	defer os.remove(artifact)

	ok := engine._import_shader("moonhug/tests/fixtures/shaders/test.glsl", artifact, engine.default_shader_settings())
	testing.expect(t, ok, "test.glsl import failed")

	blob, read_err := os.read_entire_file(artifact, context.temp_allocator)
	testing.expect(t, read_err == nil, "artifact not written")

	header, spv, msl, props, texs, parse_ok := engine._shader_artifact_parse(blob, context.temp_allocator)
	testing.expect(t, parse_ok, "artifact failed to parse")
	testing.expect(t, len(spv) > 0 && len(spv) % 4 == 0, "SPIR-V blob missing or unaligned")
	testing.expect(t, len(msl) > 0, "MSL blob missing")
	testing.expect_value(t, header.num_samplers, u32(1))
	testing.expect_value(t, header.num_uniform_buffers, u32(0))
	testing.expect_value(t, header.block_size, u32(0))
	testing.expect(t, len(props) == 0, "fixture has no property block")
	testing.expect(t, len(texs) == 1 && texs[0].binding == 0, "one reflected sampler at binding 0")

	// SPIR-V magic word.
	magic := (^u32)(raw_data(spv))^
	testing.expect_value(t, magic, u32(0x07230203))
}

// A shader with a MaterialUBO at set=3 binding=1: reflected member offsets
// land in the artifact, and num_uniform_buffers covers the sparse binding.
@(test)
test_shader_import_reflects_properties :: proc(t: ^testing.T) {
	if !_toolchain_available() {
		testing.expect(t, true)
		return
	}

	artifact := "moonhug/tests/fixtures/shaders/_test_props_artifact.bin"
	defer os.remove(artifact)

	ok := engine._import_shader("moonhug/tests/fixtures/shaders/test_props.glsl", artifact, engine.default_shader_settings())
	testing.expect(t, ok, "test_props.glsl import failed")

	blob, _ := os.read_entire_file(artifact, context.temp_allocator)
	header, _, _, props, _, parse_ok := engine._shader_artifact_parse(blob, context.temp_allocator)
	testing.expect(t, parse_ok, "artifact failed to parse")
	testing.expect_value(t, header.num_uniform_buffers, u32(2)) // binding 1 → slots 0..1
	testing.expect_value(t, header.block_size, u32(32))         // std140: float + pad + vec4
	testing.expect(t, len(props) == 2, "two reflected properties")
	if len(props) != 2 do return
	testing.expect(t, props[0].name == "mix_amount" && props[0].offset == 0 && props[0].size == 4, "float member")
	testing.expect(t, props[1].name == "rim_color" && props[1].offset == 16 && props[1].size == 16, "vec4 member")
}

// The view-dependent contract: frag_world_pos (vertex output loc 3) and the
// LightUBO's cam_pos member compile and reflect — LightUBO members must NOT
// leak into the property table (only binding 1 is the property block).
@(test)
test_shader_import_view_dependent_contract :: proc(t: ^testing.T) {
	if !_toolchain_available() {
		testing.expect(t, true)
		return
	}

	artifact := "moonhug/tests/fixtures/shaders/_test_specular_artifact.bin"
	defer os.remove(artifact)

	ok := engine._import_shader("moonhug/tests/fixtures/shaders/test_specular.glsl", artifact, engine.default_shader_settings())
	testing.expect(t, ok, "test_specular.glsl import failed")

	blob, _ := os.read_entire_file(artifact, context.temp_allocator)
	header, _, _, props, _, parse_ok := engine._shader_artifact_parse(blob, context.temp_allocator)
	testing.expect(t, parse_ok, "artifact failed to parse")
	testing.expect_value(t, header.num_uniform_buffers, u32(2)) // LightUBO(0) + MaterialUBO(1)
	testing.expect(t, len(props) == 2, "only MaterialUBO members are properties")
	if len(props) != 2 do return
	testing.expect(t, props[0].name == "spec_color" && props[0].offset == 0 && props[0].size == 16, "vec4 member")
	testing.expect(t, props[1].name == "shininess" && props[1].offset == 16 && props[1].size == 4, "float member")
}

// Samplers past binding 0 reflect into the texture table (multi-texture
// materials); num_samplers covers the highest binding.
@(test)
test_shader_import_reflects_textures :: proc(t: ^testing.T) {
	if !_toolchain_available() {
		testing.expect(t, true)
		return
	}

	artifact := "moonhug/tests/fixtures/shaders/_test_multitex_artifact.bin"
	defer os.remove(artifact)

	ok := engine._import_shader("moonhug/tests/fixtures/shaders/test_multitex.glsl", artifact, engine.default_shader_settings())
	testing.expect(t, ok, "test_multitex.glsl import failed")

	blob, _ := os.read_entire_file(artifact, context.temp_allocator)
	header, _, _, _, texs, parse_ok := engine._shader_artifact_parse(blob, context.temp_allocator)
	testing.expect(t, parse_ok, "artifact failed to parse")
	testing.expect_value(t, header.num_samplers, u32(3))
	testing.expect(t, len(texs) == 3, "three reflected samplers")
	if len(texs) != 3 do return
	// spirv-cross lists resources in declaration order.
	testing.expect(t, texs[0].name == "tex" && texs[0].binding == 0, "main sampler")
	testing.expect(t, texs[1].name == "detail_tex" && texs[1].binding == 1, "detail sampler")
	testing.expect(t, texs[2].name == "mask_tex" && texs[2].binding == 2, "mask sampler")
}

@(test)
test_shader_artifact_parse_roundtrip :: proc(t: ^testing.T) {
	spv := []u8{1, 2, 3, 4, 5, 6, 7, 8}
	msl := []u8{9, 10, 11}
	prop_name := "wobble"

	tex_name := "noise_tex"

	header := engine.Shader_Artifact_Header{
		spv_len             = u32(len(spv)),
		msl_len             = u32(len(msl)),
		num_samplers        = 2,
		num_uniform_buffers = 2,
		block_size          = 16,
		property_count      = 1,
		texture_count       = 1,
	}
	copy(header.magic[:], engine.SHADER_ARTIFACT_MAGIC)

	blob := make([dynamic]u8, context.temp_allocator)
	header_bytes := (^[size_of(engine.Shader_Artifact_Header)]u8)(&header)
	append(&blob, ..header_bytes[:])
	append(&blob, ..spv)
	append(&blob, ..msl)
	prop_offset, prop_size, name_len: u32 = 4, 4, u32(len(prop_name))
	append(&blob, ..(^[4]u8)(&prop_offset)[:])
	append(&blob, ..(^[4]u8)(&prop_size)[:])
	append(&blob, ..(^[4]u8)(&name_len)[:])
	append(&blob, ..transmute([]u8)prop_name)
	tex_binding, tex_name_len: u32 = 1, u32(len(tex_name))
	append(&blob, ..(^[4]u8)(&tex_binding)[:])
	append(&blob, ..(^[4]u8)(&tex_name_len)[:])
	append(&blob, ..transmute([]u8)tex_name)

	parsed, p_spv, p_msl, props, texs, ok := engine._shader_artifact_parse(blob[:], context.temp_allocator)
	testing.expect(t, ok, "valid blob should parse")
	testing.expect_value(t, parsed.num_uniform_buffers, u32(2))
	testing.expect_value(t, parsed.block_size, u32(16))
	testing.expect(t, len(p_spv) == 8 && p_spv[0] == 1, "spv view wrong")
	testing.expect(t, len(p_msl) == 3 && p_msl[2] == 11, "msl view wrong")
	testing.expect(t, len(props) == 1 && props[0].name == "wobble" && props[0].offset == 4, "property round-trip")
	testing.expect(t, len(texs) == 1 && texs[0].name == "noise_tex" && texs[0].binding == 1, "texture round-trip")

	_, _, _, _, _, bad := engine._shader_artifact_parse(blob[:len(blob) - 1], context.temp_allocator)
	testing.expect(t, !bad, "truncated blob accepted")
}
