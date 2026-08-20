package engine

// GUID-keyed user-shader cache (docs/Materials.md): artifact blobs →
// gfx.shader_register_fragment, keyed in gfx by the guid string, plus the
// reflected material property layout (name → UBO offset). Materials
// reference a shader asset via Material.custom_shader; resolution happens in
// _resolve_material, which packs Material.properties into the shader's UBO
// layout per draw. Editing the .glsl hot-reloads: the AssetDB refresh
// reimports the changed source and drops the cache entry + gfx pipelines,
// so the next draw re-registers from the fresh artifact.

import gfx "gfx"
import "core:encoding/uuid"
import "core:os"
import "core:strings"

Shader_Runtime :: struct {
	name:         string, // registered gfx shader-set name (owned guid string)
	block_size:   u32,    // material UBO byte size; 0 = no property block
	num_samplers: u32,    // fragment sampler slots (max binding + 1)
	properties:   []Shader_Property, // owned (names too)
	textures:     []Shader_Texture,  // owned (names too); bindings 1+ are material rows
}

shader_cache: map[Asset_GUID]Shader_Runtime
_shader_cache_ready: bool

// Guids whose last load attempt failed (compile error, missing toolchain,
// bad artifact). A failed load is NOT retried per call — the retry runs the
// shader toolchain as subprocesses, and shader_load is called per draw, so
// retrying would spawn glslc every frame. The memo clears when the source
// changes (shader_path_changed), giving one retry per edit.
@(private = "file") _shader_failed: map[Asset_GUID]bool

shader_cache_init :: proc() {
	shader_cache = make(map[Asset_GUID]Shader_Runtime)
	_shader_failed = make(map[Asset_GUID]bool)
	_shader_cache_ready = true
}

shader_cache_shutdown :: proc() {
	for _, &sr in shader_cache {
		_shader_runtime_destroy(&sr)
	}
	delete(shader_cache)
	shader_cache = nil
	delete(_shader_failed)
	_shader_failed = nil
	_shader_cache_ready = false
}

_shader_runtime_destroy :: proc(sr: ^Shader_Runtime) {
	delete(sr.name)
	for prop in sr.properties {
		delete(prop.name)
	}
	delete(sr.properties)
	for tex in sr.textures {
		delete(tex.name)
	}
	delete(sr.textures)
	sr^ = {}
}

shader_load :: proc(guid: Asset_GUID) -> (^Shader_Runtime, bool) {
	if cached, hit := &shader_cache[guid]; hit {
		return cached, true
	}
	if !_shader_cache_ready do return nil, false
	if guid in _shader_failed do return nil, false
	// Headless contexts (tests, scene tooling) have no GPU device.
	if gfx.device() == nil do return nil, false

	artifact := _artifact_path(uuid.Identifier(guid))
	defer delete(artifact)

	header: Shader_Artifact_Header
	spv, msl: []u8
	properties: []Shader_Property
	textures: []Shader_Texture
	parse_ok := false
	blob, read_err := os.read_entire_file(artifact, context.temp_allocator)
	if read_err == nil {
		header, spv, msl, properties, textures, parse_ok = _shader_artifact_parse(blob)
	}
	if !parse_ok {
		// Artifact missing (fresh clone, cleaned library/) or stale (format
		// bump): import from source and retry once (needs the toolchain).
		source_path, path_ok := asset_db_get_path(uuid.Identifier(guid))
		if !path_ok do return nil, false
		if !asset_pipeline_reimport(source_path) {
			_shader_failed[guid] = true
			return nil, false
		}
		blob, read_err = os.read_entire_file(artifact, context.temp_allocator)
		if read_err != nil {
			_shader_failed[guid] = true
			return nil, false
		}
		header, spv, msl, properties, textures, parse_ok = _shader_artifact_parse(blob)
		if !parse_ok {
			_shader_failed[guid] = true
			return nil, false
		}
	}

	guid_str := uuid.to_string(uuid.Identifier(guid), context.temp_allocator)
	// A leftover registration (cache cleared without unregister) is reused.
	if !gfx.shader_exists(guid_str) {
		if !gfx.shader_register_fragment(guid_str, spv, msl, header.num_samplers, header.num_uniform_buffers) {
			for prop in properties do delete(prop.name)
			delete(properties)
			for tex in textures do delete(tex.name)
			delete(textures)
			_shader_failed[guid] = true
			return nil, false
		}
	}
	shader_cache[guid] = Shader_Runtime{
		name         = strings.clone(guid_str),
		block_size   = header.block_size,
		num_samplers = header.num_samplers,
		properties   = properties,
		textures     = textures,
	}
	return &shader_cache[guid], true
}

shader_unload :: proc(guid: Asset_GUID) {
	if sr, hit := &shader_cache[guid]; hit {
		gfx.shader_unregister(sr.name)
		_shader_runtime_destroy(sr)
		delete_key(&shader_cache, guid)
	}
}

// AssetDB hook (change + delete). Reimport is mtime-guarded, so refresh
// passes that didn't touch the source are free. A changed source clears the
// failed memo — the edit earns one fresh compile attempt. When the compile
// fails, the index keeps pointing at the last GOOD artifact (it only
// re-points on success), so the next shader_load re-registers the previous
// working pipelines instead of dropping the draw.
shader_path_changed :: proc(path: string) {
	if !strings.has_suffix(path, ".glsl") do return
	guid, ok := asset_db_get_guid(path)
	if !ok do return
	delete_key(&_shader_failed, Asset_GUID(guid))
	_ = asset_pipeline_import_asset(path)
	shader_unload(Asset_GUID(guid))
}
