package physics3d

// The convex decompositions of a model, for MeshColliders a Rigidbody
// carries. A model lists them in its import settings (engine.Mesh_Hull_Set:
// which mesh, how many hulls, how concave), the editor computes each one
// after the import (editor/hull_jobs.odin) and saves it beside the model's
// artifact as <artifact key>_h<set id>.bin, and in the model's .meta, which
// is committed: a fresh clone or a reimport restores every set whose mesh
// and settings did not change from the meta, and computes only the rest.
// The file shares the artifact's key, so the catalog export ships it with
// the model. A game only reads the files.

import "base:runtime"
import "core:bytes"
import "core:encoding/endian"
import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:strings"
import "moonhug:packages/engine"

// Bumped when the file layout or the decomposition's fixed parameters
// change: it is part of each file's source hash, so older files stop
// matching and are computed again.
MESH_HULLS_VERSION :: 2

@(private = "file") _MAGIC :: u32(0x4843484D) // "MHCH"

Mesh_Hulls_State :: enum {
	Ready,
	// No file yet, and the editor is computing it or has it queued.
	Pending,
	// No file, and nothing computes one: the set is gone from the model,
	// its decomposition failed or was cancelled, or a game misses the file.
	Missing,
}

// Whether the editor is computing or has queued a set of this model.
// Installed by the editor, nil in a game.
mesh_hulls_pending: proc(guid: engine.Asset_GUID, set: engine.Local_ID) -> bool

// Loaded hull sets by file path, kept until any reimport.
@(private = "file") _hull_sets: map[string][][][3]f32

// The hulls of a model's set, owned by the cache.
mesh_hulls :: proc(guid: engine.Asset_GUID, set: engine.Local_ID) -> ([][][3]f32, Mesh_Hulls_State) {
	path, pok := mesh_hulls_path(guid, set)
	if !pok do return nil, .Missing
	if hulls, cached := _hull_sets[path]; cached do return hulls, .Ready

	context.allocator = runtime.default_allocator()
	@(static) hooked := false
	if !hooked {
		hooked = true
		_hull_sets = make(map[string][][][3]f32)
		engine.asset_pipeline_add_reimport_hook(_hull_sets_drop)
	}
	if _, hulls, ok := mesh_hulls_read(path, context.allocator); ok {
		_hull_sets[strings.clone(path)] = hulls
		return hulls, .Ready
	}
	if mesh_hulls_pending != nil && mesh_hulls_pending(guid, set) do return nil, .Pending
	return nil, .Missing
}

// "<model artifact minus .bin>_h<set id>.bin". Temp-allocated. ok=false
// when the model has no artifact.
mesh_hulls_path :: proc(guid: engine.Asset_GUID, set: engine.Local_ID) -> (string, bool) {
	artifact, ok := engine.asset_pipeline_artifact_path(guid)
	if !ok do return "", false
	return mesh_hulls_path_of(artifact, set), true
}

// The same, beside a given artifact path.
mesh_hulls_path_of :: proc(artifact: string, set: engine.Local_ID) -> string {
	return fmt.tprintf("%s_h%d.bin", strings.trim_suffix(artifact, ".bin"), set)
}

// What a set's hulls are computed from: the mesh's positions and triangles,
// the set's settings and MESH_HULLS_VERSION. Equal hashes mean equal hulls.
mesh_hulls_source_hash :: proc(positions: [][3]f32, indices: []u32, max_hulls: i32, concavity: f32) -> u64 {
	state, _ := xxhash.XXH3_create_state(context.temp_allocator)
	settings := struct {
		version:   i32,
		max_hulls: i32,
		concavity: f32,
	}{MESH_HULLS_VERSION, max_hulls, concavity}
	xxhash.XXH3_64_update(state, ([^]byte)(&settings)[:size_of(settings)])
	xxhash.XXH3_64_update(state, ([^]byte)(raw_data(positions))[:len(positions) * size_of([3]f32)])
	xxhash.XXH3_64_update(state, ([^]byte)(raw_data(indices))[:len(indices) * size_of(u32)])
	return u64(xxhash.XXH3_64_digest(state))
}

// Frees a hull list allocated on `allocator`.
mesh_hulls_free :: proc(hulls: [][][3]f32, allocator := context.allocator) {
	for h in hulls do delete(h, allocator)
	delete(hulls, allocator)
}

// Every cached set goes: the reimported model has a new key, so its old file
// names no longer resolve, and the other models' sets reload cheaply.
@(private = "file")
_hull_sets_drop :: proc(guid: engine.Asset_GUID) {
	context.allocator = runtime.default_allocator()
	for path, hulls in _hull_sets {
		delete(path)
		mesh_hulls_free(hulls)
	}
	clear(&_hull_sets)
}

// Layout, little endian: magic, version, the source hash (two u32, low
// first), hull count, then per hull its point count and the points as three
// f32 each. The editor keeps the same bytes in the model's .meta.
// Temp-allocated.
mesh_hulls_encode :: proc(source_hash: u64, hulls: [][][3]f32) -> []byte {
	buf: bytes.Buffer
	bytes.buffer_init_allocator(&buf, 0, 1024, context.temp_allocator)
	put :: proc(buf: ^bytes.Buffer, v: u32) {
		b: [4]byte
		endian.put_u32(b[:], .Little, v)
		bytes.buffer_write(buf, b[:])
	}
	put(&buf, _MAGIC)
	put(&buf, MESH_HULLS_VERSION)
	put(&buf, u32(source_hash))
	put(&buf, u32(source_hash >> 32))
	put(&buf, u32(len(hulls)))
	for h in hulls {
		put(&buf, u32(len(h)))
		for p in h do for c in p do put(&buf, transmute(u32)c)
	}
	return bytes.buffer_to_bytes(&buf)
}

// Writes encoded hulls to a file. False when it cannot be written.
mesh_hulls_write :: proc(path: string, data: []byte) -> bool {
	engine._ensure_artifact_dir(path)
	return os.write_entire_file(path, data) == nil
}

mesh_hulls_read :: proc(path: string, allocator := context.allocator) -> (source_hash: u64, hulls: [][][3]f32, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return 0, nil, false
	return mesh_hulls_decode(data, allocator)
}

// Encoded hulls back to their source hash and hulls, the hulls on
// `allocator`. ok=false for foreign or truncated bytes.
mesh_hulls_decode :: proc(data: []byte, allocator := context.allocator) -> (source_hash: u64, hulls: [][][3]f32, ok: bool) {
	source_hash = mesh_hulls_data_hash(data) or_return
	at := 16
	get :: proc(data: []byte, at: ^int) -> (u32, bool) {
		if at^ + 4 > len(data) do return 0, false
		v, _ := endian.get_u32(data[at^:], .Little)
		at^ += 4
		return v, true
	}
	count := get(data, &at) or_return
	if int(count) > len(data) / 4 do return 0, nil, false
	out := make([dynamic][][3]f32, 0, count, allocator)
	for _ in 0 ..< count {
		n, nok := get(data, &at)
		if !nok || at + int(n) * 12 > len(data) {
			mesh_hulls_free(out[:], allocator)
			return 0, nil, false
		}
		h := make([][3]f32, n, allocator)
		for &p in h do for &c in p {
			v, _ := get(data, &at)
			c = transmute(f32)v
		}
		append(&out, h)
	}
	return source_hash, out[:], true
}

// The source hash at the head of encoded hulls.
mesh_hulls_data_hash :: proc(data: []byte) -> (u64, bool) {
	if len(data) < 16 do return 0, false
	magic, _ := endian.get_u32(data[0:], .Little)
	version, _ := endian.get_u32(data[4:], .Little)
	if magic != _MAGIC || version != MESH_HULLS_VERSION do return 0, false
	lo, _ := endian.get_u32(data[8:], .Little)
	hi, _ := endian.get_u32(data[12:], .Little)
	return u64(lo) | u64(hi) << 32, true
}

// The source hash recorded in a hull file, without reading its hulls.
mesh_hulls_file_hash :: proc(path: string) -> (u64, bool) {
	f, err := os.open(path)
	if err != nil do return 0, false
	defer os.close(f)
	head: [16]byte
	n, rerr := os.read(f, head[:])
	if rerr != nil || n < 16 do return 0, false
	return mesh_hulls_data_hash(head[:])
}
