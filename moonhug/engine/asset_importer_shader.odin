package engine

// User shader importer (docs/Materials.md). A `.glsl` asset is a FRAGMENT
// shader only — the vertex stage is always the built-in world vertex shader,
// since the vertex format and UBO layout are fixed engine contracts. Import
// shells out to the same toolchain as `mh shaders` (glslc → SPIR-V,
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

@(typ_guid={guid="fa4de399-c86a-47fa-821f-ddd6276562ad", makeProcName=make_pShaderSettings})
ShaderSettings :: struct {
}

make_pShaderSettings :: proc() -> any {
    p := new(ShaderSettings)
    return p^
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
