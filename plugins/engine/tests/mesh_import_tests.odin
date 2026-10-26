package engine_tests

// glTF mesh importer tests (plugins/engine/docs/SDL3Renderer.md #5). Headless: they exercise
// import + artifact parsing only — GPU upload (mesh_load) needs a device and
// is covered by using the editor. cube.glb is a generated 24-vert/36-index
// unit cube with normals + uvs.

import "core:math/linalg"
import "core:os"
import "core:testing"
import gfx "moonhug:libs/gfx"
import "moonhug:packages/engine"
import "moonhug:packages/engine/editor/importers"

CUBE_GLB :: "moonhug/tests/fixtures/meshes/cube.glb"

// Where the import tests write their artifacts. An import writes the whole
// model plus a part file per glTF mesh, so each test removes the folder, not
// the files it names, and nothing lands beside the fixtures.
@(private = "file")
_MESH_TMP :: "moonhug/tests/fixtures/_mesh_import_tmp"

@(test)
test_mesh_import_cube_glb :: proc(t: ^testing.T) {
	artifact := _MESH_TMP + "/cube_test.bin"
	defer _remove_tree(_MESH_TMP)
	// A bare import mints the first mesh's part id as 1, the file's name.
	part0 := engine.artifact_sub_path(artifact, 1, context.temp_allocator)

	ok := importers._import_mesh(CUBE_GLB, artifact, nil)
	testing.expect(t, ok, "cube.glb import failed")

	// Import also writes one node-local PART artifact per glTF mesh, named by
	// its part id. The single-mesh cube's part matches the whole model.
	part_blob, part_err := os.read_entire_file(part0, context.temp_allocator)
	testing.expect(t, part_err == nil, "part artifact not written")
	if part_err == nil {
		ph, _, _, psubs, p_ok := engine._mesh_artifact_parse(part_blob)
		testing.expect(t, p_ok, "part artifact failed to parse")
		testing.expect_value(t, ph.vertex_count, u32(24))
		testing.expect(t, len(psubs) == 1, "single-material cube part = one submesh")
	}

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
		// cube.glb has no tangents: generated ones are unit length, at right
		// angles to the normal, with a sign in w.
		tl := linalg.length(v.tangent.xyz)
		testing.expectf(t, abs(tl - 1) < 1e-4, "generated tangent not unit length: %v", v.tangent)
		testing.expectf(t, abs(linalg.dot(v.tangent.xyz, n)) < 1e-4, "tangent not perpendicular to the normal: %v %v", v.tangent, n)
		testing.expect(t, v.tangent.w == 1 || v.tangent.w == -1, "tangent w is the bitangent sign")
	}
}

// A quad facing +Z with u along +X: the tangent is +X, and the bitangent
// (cross(normal, tangent) * w) runs the way v grows. Mirroring u flips the
// tangent's direction, mirroring v flips w.
@(test)
test_mesh_generate_tangents :: proc(t: ^testing.T) {
	quad :: proc(uvs: [4][2]f32) -> [4]gfx.Vertex {
		p := [4][3]f32{{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}}
		out: [4]gfx.Vertex
		for i in 0 ..< 4 do out[i] = gfx.Vertex{position = p[i], normal = {0, 0, 1}, uv = uvs[i]}
		return out
	}
	indices := []u32{10, 11, 12, 10, 12, 13} // based at 10, as in a mesh with earlier primitives

	v := quad({{0, 0}, {1, 0}, {1, 1}, {0, 1}})
	importers.mesh_generate_tangents(v[:], indices, 10)
	for x in v do testing.expectf(t, x.tangent == {1, 0, 0, 1}, "u along +x, v along +y: got %v", x.tangent)

	v = quad({{1, 0}, {0, 0}, {0, 1}, {1, 1}}) // u mirrored
	importers.mesh_generate_tangents(v[:], indices, 10)
	for x in v do testing.expectf(t, x.tangent == {-1, 0, 0, -1}, "u mirrored: got %v", x.tangent)

	v = quad({{0, 1}, {1, 1}, {1, 0}, {0, 0}}) // v mirrored, the image convention
	importers.mesh_generate_tangents(v[:], indices, 10)
	for x in v do testing.expectf(t, x.tangent == {1, 0, 0, -1}, "v mirrored: got %v", x.tangent)
}

@(test)
test_mesh_import_respects_scale_setting :: proc(t: ^testing.T) {
	artifact := _MESH_TMP + "/cube_scaled.bin"
	defer _remove_tree(_MESH_TMP)

	scaled := engine.MeshSettings{scale = 2}
	ok := importers._import_mesh(CUBE_GLB, artifact, &scaled)
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
	artifact := _MESH_TMP + "/multimat_test.bin"
	defer _remove_tree(_MESH_TMP)

	ok := importers._import_mesh("moonhug/tests/fixtures/meshes/multimat_cube.glb", artifact, nil)
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
