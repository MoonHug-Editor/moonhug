package engine

// User shader importer (docs/Materials.md). A `.glsl` asset is a FRAGMENT
// shader only — the vertex stage is always the built-in world vertex shader,
// since the vertex format and UBO layout are fixed engine contracts. Import
// shells out to the same toolchain as shaders/compile.sh (glslc → SPIR-V,
// spirv-cross → MSL + reflection) and caches both blobs in the artifact;
// contributors WITHOUT the toolchain can still open the project — only
// authoring/editing shaders needs `brew install shaderc spirv-cross`.
//
// The source must follow the built-in fragment conventions (see
// assets/shaders/normals.glsl): inputs frag_uv/frag_color/frag_normal,
// sampler2D at set=2 binding=0, optional LightUBO at set=3 binding=0, and
// optionally a MATERIAL PROPERTY BLOCK at set=3 binding=1 — its reflected
// std140 layout (member names/offsets/block size) is stored in the artifact
// and fed per-draw from Material.properties.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "log"

@(typ_guid={guid="fa4de399-c86a-47fa-821f-ddd6276562ad"})
ShaderSettings :: struct {
}

default_shader_settings :: proc() -> ShaderSettings {
    return ShaderSettings{}
}

// Fragment UBO slot the property block binds to (slot 0 is the LightUBO).
SHADER_MATERIAL_UBO_BINDING :: 1

// One member of the shader's material property block: where Material
// property values land inside the pushed UBO bytes.
Shader_Property :: struct {
    name:   string,
    offset: u32,
    size:   u32, // float=4, vec2=8, vec3=12, vec4=16
}

// One reflected sampler2D (set=2). Binding 0 is the main texture (fed by
// Material.texture / the sprite's own texture); bindings 1+ become named
// texture rows on the Material, matched by name like properties.
Shader_Texture :: struct {
    name:    string,
    binding: u32,
}

// Fragment sampler slots the engine will bind per draw (SDL_GPU wants the
// exact count the pipeline declares). Shaders with more samplers fail import.
SHADER_MAX_SAMPLERS :: 8

// Artifact layout (little-endian): header | spirv | msl | property table
// (per property: offset u32 | size u32 | name_len u32 | name bytes) |
// texture table (per texture: binding u32 | name_len u32 | name bytes).
// v2 added the property table + block_size; v3 fixed MSL buffer indices
// (--msl-decoration-binding); v4 added the texture table (multi-texture
// materials). Stale artifacts fail the magic check and shader_load reimports
// from source.
SHADER_ARTIFACT_MAGIC :: "MHSHDR4\x00"

Shader_Artifact_Header :: struct #packed {
    magic:               [8]u8,
    spv_len:             u32,
    msl_len:             u32,
    num_samplers:        u32, // max binding + 1 (bindings may be sparse)
    num_uniform_buffers: u32, // max binding + 1 (bindings may be sparse)
    block_size:          u32, // material UBO byte size; 0 = no property block
    property_count:      u32,
    texture_count:       u32,
}

_import_shader :: proc(source_path: string, artifact_path: string, settings: ImportSettings) -> bool {
    tmp_spv := strings.concatenate({artifact_path, ".spv.tmp"}, context.temp_allocator)
    tmp_msl := strings.concatenate({artifact_path, ".msl.tmp"}, context.temp_allocator)
    tmp_json := strings.concatenate({artifact_path, ".json.tmp"}, context.temp_allocator)
    defer os.remove(tmp_spv)
    defer os.remove(tmp_msl)
    defer os.remove(tmp_json)

    _ensure_artifact_dir(artifact_path)

    // Input file FIRST for spirv-cross: --reflect greedily consumes a
    // following bare argument as its optional format, eating the input path.
    // --msl-decoration-binding: keep GLSL binding numbers as Metal buffer
    // indices — by default spirv-cross assigns them SEQUENTIALLY, so a lone
    // MaterialUBO at binding=1 would land at buffer(0) while the engine
    // pushes property data to slot 1 (silently reading the light UBO).
    if !_run_tool({"glslc", "-fshader-stage=frag", source_path, "-o", tmp_spv}, source_path) do return false
    if !_run_tool({"spirv-cross", tmp_spv, "--msl", "--msl-decoration-binding", "--output", tmp_msl}, source_path) do return false
    if !_run_tool({"spirv-cross", tmp_spv, "--reflect", "--output", tmp_json}, source_path) do return false

    spv, spv_err := os.read_entire_file(tmp_spv, context.temp_allocator)
    msl, msl_err := os.read_entire_file(tmp_msl, context.temp_allocator)
    reflect_data, json_err := os.read_entire_file(tmp_json, context.temp_allocator)
    if spv_err != nil || msl_err != nil || json_err != nil {
        log.errorf("[Pipeline] Shader tool output missing: %s", source_path)
        return false
    }

    reflect, reflect_ok := _shader_reflect(reflect_data)
    if !reflect_ok {
        log.errorf("[Pipeline] Failed to parse shader reflection: %s", source_path)
        return false
    }

    if reflect.num_samplers > SHADER_MAX_SAMPLERS {
        log.errorf("[Pipeline] %s declares sampler binding %d — max is %d",
            source_path, reflect.num_samplers - 1, SHADER_MAX_SAMPLERS - 1)
        return false
    }

    header := Shader_Artifact_Header{
        spv_len             = u32(len(spv)),
        msl_len             = u32(len(msl)),
        num_samplers        = reflect.num_samplers,
        num_uniform_buffers = reflect.num_uniform_buffers,
        block_size          = reflect.block_size,
        property_count      = u32(len(reflect.properties)),
        texture_count       = u32(len(reflect.textures)),
    }
    copy(header.magic[:], SHADER_ARTIFACT_MAGIC)

    blob := make([dynamic]u8, 0, size_of(header) + len(spv) + len(msl) + 256, context.temp_allocator)
    header_bytes := (^[size_of(Shader_Artifact_Header)]u8)(&header)
    append(&blob, ..header_bytes[:])
    append(&blob, ..spv)
    append(&blob, ..msl)
    for prop in reflect.properties {
        _blob_append_u32(&blob, prop.offset)
        _blob_append_u32(&blob, prop.size)
        _blob_append_u32(&blob, u32(len(prop.name)))
        append(&blob, ..transmute([]u8)prop.name)
    }
    for tex in reflect.textures {
        _blob_append_u32(&blob, tex.binding)
        _blob_append_u32(&blob, u32(len(tex.name)))
        append(&blob, ..transmute([]u8)tex.name)
    }

    if write_err := os.write_entire_file(artifact_path, blob[:]); write_err != nil {
        log.errorf("[Pipeline] Failed to write shader artifact: %s", artifact_path)
        return false
    }

    fmt.printf("[Pipeline] Imported shader: %s -> %s (%d samplers, %d ubos, %d properties)\n",
        source_path, artifact_path, header.num_samplers, header.num_uniform_buffers, header.property_count)
    return true
}

_blob_append_u32 :: proc(blob: ^[dynamic]u8, v: u32) {
    v := v
    bytes := (^[4]u8)(&v)
    append(blob, ..bytes[:])
}

// Runs a toolchain command; compile errors land in the editor console with
// the tool's stderr. A missing executable gets the install hint.
_run_tool :: proc(command: []string, source_path: string) -> bool {
    state, _, stderr, err := os.process_exec({command = command}, context.temp_allocator)
    if err != nil {
        log.errorf("[Pipeline] Could not run %s (%v) — shader authoring needs `brew install shaderc spirv-cross`", command[0], err)
        return false
    }
    if !state.exited || state.exit_code != 0 {
        log.errorf("[Pipeline] %s failed for %s:\n%s", command[0], source_path, string(stderr))
        return false
    }
    return true
}

_Shader_Reflect :: struct {
    num_samplers:        u32,
    num_uniform_buffers: u32,
    block_size:          u32,
    properties:          [dynamic]Shader_Property, // temp-allocated names
    textures:            [dynamic]Shader_Texture,  // temp-allocated names
}

// From spirv-cross --reflect JSON: sampled images under "textures", uniform
// blocks under "ubos" (num = max binding + 1 — a shader may declare the
// material block without the light block), material property members from
// the "types" entry of the binding-1 block.
_shader_reflect :: proc(data: []u8) -> (result: _Shader_Reflect, ok: bool) {
    value, err := json.parse(data, allocator = context.temp_allocator)
    if err != nil do return
    root, is_obj := value.(json.Object)
    if !is_obj do return

    result.textures = make([dynamic]Shader_Texture, context.temp_allocator)
    if textures, has := root["textures"].(json.Array); has {
        for entry in textures {
            tex, entry_ok := entry.(json.Object)
            if !entry_ok do continue
            name, n_ok := tex["name"].(json.String)
            if !n_ok do continue
            binding := u32(0)
            if b, b_ok := tex["binding"].(json.Float); b_ok do binding = u32(b)
            result.num_samplers = max(result.num_samplers, binding + 1)
            append(&result.textures, Shader_Texture{name = name, binding = binding})
        }
    }

    result.properties = make([dynamic]Shader_Property, context.temp_allocator)
    if ubos, has := root["ubos"].(json.Array); has {
        for entry in ubos {
            ubo, entry_ok := entry.(json.Object)
            if !entry_ok do continue
            binding := u32(0)
            if b, b_ok := ubo["binding"].(json.Float); b_ok do binding = u32(b)
            result.num_uniform_buffers = max(result.num_uniform_buffers, binding + 1)

            if binding != SHADER_MATERIAL_UBO_BINDING do continue
            if size, s_ok := ubo["block_size"].(json.Float); s_ok do result.block_size = u32(size)

            type_id, t_ok := ubo["type"].(json.String)
            if !t_ok do continue
            types, types_ok := root["types"].(json.Object)
            if !types_ok do continue
            type_obj, to_ok := types[type_id].(json.Object)
            if !to_ok do continue
            members, m_ok := type_obj["members"].(json.Array)
            if !m_ok do continue
            for member in members {
                mo, mo_ok := member.(json.Object)
                if !mo_ok do continue
                name, n_ok := mo["name"].(json.String)
                mtype, mt_ok := mo["type"].(json.String)
                if !n_ok || !mt_ok do continue
                offset := u32(0)
                if o, o_ok := mo["offset"].(json.Float); o_ok do offset = u32(o)
                size: u32
                switch mtype {
                case "float": size = 4
                case "vec2":  size = 8
                case "vec3":  size = 12
                case "vec4":  size = 16
                case:
                    continue // matrices/ints/arrays: unsupported property types, skipped
                }
                append(&result.properties, Shader_Property{name = name, offset = offset, size = size})
            }
        }
    }
    return result, true
}

// Validates an artifact blob; spv/msl are views into it, property/texture
// names are CLONED with `allocator` (callers keep them past the blob).
// Shared by shader_load and tests.
_shader_artifact_parse :: proc(blob: []u8, allocator := context.allocator) -> (header: Shader_Artifact_Header, spv: []u8, msl: []u8, properties: []Shader_Property, textures: []Shader_Texture, ok: bool) {
    if len(blob) < size_of(Shader_Artifact_Header) do return
    header = (^Shader_Artifact_Header)(raw_data(blob))^
    if string(header.magic[:]) != SHADER_ARTIFACT_MAGIC do return
    if len(blob) < size_of(Shader_Artifact_Header) + int(header.spv_len) + int(header.msl_len) do return

    spv = blob[size_of(Shader_Artifact_Header):][:header.spv_len]
    msl = blob[size_of(Shader_Artifact_Header) + int(header.spv_len):][:header.msl_len]

    props := make([dynamic]Shader_Property, 0, header.property_count, allocator)
    cursor := size_of(Shader_Artifact_Header) + int(header.spv_len) + int(header.msl_len)
    for _ in 0 ..< header.property_count {
        if cursor + 12 > len(blob) do return {}, nil, nil, nil, nil, false
        offset := (^u32)(raw_data(blob[cursor:]))^
        size := (^u32)(raw_data(blob[cursor + 4:]))^
        name_len := int((^u32)(raw_data(blob[cursor + 8:]))^)
        cursor += 12
        if cursor + name_len > len(blob) do return {}, nil, nil, nil, nil, false
        name := strings.clone(string(blob[cursor:][:name_len]), allocator)
        cursor += name_len
        append(&props, Shader_Property{name = name, offset = offset, size = size})
    }
    texs := make([dynamic]Shader_Texture, 0, header.texture_count, allocator)
    for _ in 0 ..< header.texture_count {
        if cursor + 8 > len(blob) do return {}, nil, nil, nil, nil, false
        binding := (^u32)(raw_data(blob[cursor:]))^
        name_len := int((^u32)(raw_data(blob[cursor + 4:]))^)
        cursor += 8
        if cursor + name_len > len(blob) do return {}, nil, nil, nil, nil, false
        name := strings.clone(string(blob[cursor:][:name_len]), allocator)
        cursor += name_len
        append(&texs, Shader_Texture{name = name, binding = binding})
    }
    if cursor != len(blob) do return {}, nil, nil, nil, nil, false
    return header, spv, msl, props[:], texs[:], true
}
