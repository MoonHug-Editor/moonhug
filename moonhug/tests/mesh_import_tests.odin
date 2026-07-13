package tests

// glTF mesh importer tests (docs/SDL3Renderer.md #5). Headless: they exercise
// import + artifact parsing only — GPU upload (mesh_load) needs a device and
// is covered by using the editor. cube.glb is a generated 24-vert/36-index
// unit cube with normals + uvs.

import "core:os"
import "core:testing"
import "../engine"

CUBE_GLB :: "moonhug/tests/fixtures/meshes/cube.glb"

@(test)
test_mesh_import_cube_glb :: proc(t: ^testing.T) {
	artifact := "moonhug/tests/fixtures/meshes/_cube_test_artifact.bin"
	defer os.remove(artifact)

	ok := engine._import_mesh(CUBE_GLB, artifact, engine.default_mesh_settings())
	testing.expect(t, ok, "cube.glb import failed")

	blob, read_err := os.read_entire_file(artifact, context.temp_allocator)
	testing.expect(t, read_err == nil, "artifact not written")

	header, vertices, indices, submeshes, parse_ok := engine._mesh_artifact_parse(blob)
	testing.expect(t, parse_ok, "artifact failed to parse")
	testing.expect_value(t, header.vertex_count, u32(24))
	testing.expect_value(t, header.index_count, u32(36))
	testing.expect_value(t, header.submesh_count, u32(1))
	testing.expect(t, len(vertices) == 24 && len(indices) == 36, "view lengths mismatch")
	testing.expect(t, len(submeshes) == 1 && submeshes[0] == {0, 36}, "single-material cube = one full-range submesh")

	for i in 0 ..< 3 {
		testing.expect(t, abs(header.aabb_min[i] + 0.5) < 1e-5, "aabb_min not -0.5")
		testing.expect(t, abs(header.aabb_max[i] - 0.5) < 1e-5, "aabb_max not +0.5")
	}

	// All indices in range; normals unit-length; uvs within [0,1].
	for idx in indices {
		testing.expect(t, idx < header.vertex_count, "index out of range")
	}
	for &v in vertices {
		n := v.normal
		len_sq := n.x * n.x + n.y * n.y + n.z * n.z
		testing.expect(t, abs(len_sq - 1) < 1e-4, "normal not unit length")
		testing.expect(t, v.uv.x >= 0 && v.uv.x <= 1 && v.uv.y >= 0 && v.uv.y <= 1, "uv out of range")
	}
}

@(test)
test_mesh_import_respects_scale_setting :: proc(t: ^testing.T) {
	artifact := "moonhug/tests/fixtures/meshes/_cube_scaled_artifact.bin"
	defer os.remove(artifact)

	ok := engine._import_mesh(CUBE_GLB, artifact, engine.MeshSettings{scale = 2})
	testing.expect(t, ok, "scaled import failed")

	blob, _ := os.read_entire_file(artifact, context.temp_allocator)
	header, _, _, _, parse_ok := engine._mesh_artifact_parse(blob)
	testing.expect(t, parse_ok, "scaled artifact failed to parse")
	for i in 0 ..< 3 {
		testing.expect(t, abs(header.aabb_min[i] + 1) < 1e-5, "scaled aabb_min not -1")
		testing.expect(t, abs(header.aabb_max[i] - 1) < 1e-5, "scaled aabb_max not +1")
	}
}

@(test)
test_mesh_artifact_parse_rejects_garbage :: proc(t: ^testing.T) {
	_, _, _, _, ok := engine._mesh_artifact_parse([]u8{1, 2, 3})
	testing.expect(t, !ok, "short blob accepted")

	junk := make([]u8, 128, context.temp_allocator)
	_, _, _, _, ok = engine._mesh_artifact_parse(junk)
	testing.expect(t, !ok, "bad magic accepted")
}

// Two glTF materials (4 side faces / 2 cap faces) → two submeshes whose index
// ranges partition the blob in first-appearance order.
@(test)
test_mesh_import_multimaterial_submeshes :: proc(t: ^testing.T) {
	artifact := "moonhug/tests/fixtures/meshes/_multimat_test_artifact.bin"
	defer os.remove(artifact)

	ok := engine._import_mesh("moonhug/tests/fixtures/meshes/multimat_cube.glb", artifact, engine.default_mesh_settings())
	testing.expect(t, ok, "multimat_cube.glb import failed")

	blob, read_err := os.read_entire_file(artifact, context.temp_allocator)
	testing.expect(t, read_err == nil, "artifact not written")

	header, vertices, indices, submeshes, parse_ok := engine._mesh_artifact_parse(blob)
	testing.expect(t, parse_ok, "artifact failed to parse")
	testing.expect_value(t, header.vertex_count, u32(24))
	testing.expect_value(t, header.index_count, u32(36))
	testing.expect_value(t, header.submesh_count, u32(2))
	testing.expect(t, submeshes[0] == {0, 24}, "sides submesh = first 24 indices")
	testing.expect(t, submeshes[1] == {24, 12}, "caps submesh = last 12 indices")

	testing.expect(t, len(vertices) == 24, "vertex view length")
	for idx in indices {
		testing.expect(t, idx < header.vertex_count, "index out of range")
	}
}
