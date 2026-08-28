package asset_pipeline

// User shader importer (docs/Materials.md). A `.glsl` asset is a FRAGMENT
// shader only — the vertex stage is always the built-in world vertex shader.
// Import shells out to the same toolchain as `mh shaders` (glslc →
// SPIR-V, spirv-cross → MSL + reflection) and caches both blobs in the
// artifact; contributors WITHOUT the toolchain can still open the project —
// only authoring/editing shaders needs `brew install shaderc spirv-cross`.
// The artifact FORMAT and its parse live in the engine
// (asset_importer_shader.odin) — runtime shader loading reads them.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "moonhug:engine"
import "moonhug:engine/log"

_import_shader :: proc(source_path: string, artifact_path: string, settings: rawptr) -> bool {
    tmp_spv := strings.concatenate({artifact_path, ".spv.tmp"}, context.temp_allocator)
    tmp_msl := strings.concatenate({artifact_path, ".msl.tmp"}, context.temp_allocator)
    tmp_json := strings.concatenate({artifact_path, ".json.tmp"}, context.temp_allocator)
    defer os.remove(tmp_spv)
    defer os.remove(tmp_msl)
    defer os.remove(tmp_json)

    engine._ensure_artifact_dir(artifact_path)

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

    if reflect.num_samplers > engine.SHADER_MAX_SAMPLERS {
        log.errorf("[Pipeline] %s declares sampler binding %d — max is %d",
            source_path, reflect.num_samplers - 1, engine.SHADER_MAX_SAMPLERS - 1)
        return false
    }

    header := engine.Shader_Artifact_Header{
        spv_len             = u32(len(spv)),
        msl_len             = u32(len(msl)),
        num_samplers        = reflect.num_samplers,
        num_uniform_buffers = reflect.num_uniform_buffers,
        block_size          = reflect.block_size,
        property_count      = u32(len(reflect.properties)),
        texture_count       = u32(len(reflect.textures)),
    }
    copy(header.magic[:], engine.SHADER_ARTIFACT_MAGIC)

    blob := make([dynamic]u8, 0, size_of(header) + len(spv) + len(msl) + 256, context.temp_allocator)
    header_bytes := (^[size_of(engine.Shader_Artifact_Header)]u8)(&header)
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
    properties:          [dynamic]engine.Shader_Property, // temp-allocated names
    textures:            [dynamic]engine.Shader_Texture,  // temp-allocated names
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

    result.textures = make([dynamic]engine.Shader_Texture, context.temp_allocator)
    if textures, has := root["textures"].(json.Array); has {
        for entry in textures {
            tex, entry_ok := entry.(json.Object)
            if !entry_ok do continue
            name, n_ok := tex["name"].(json.String)
            if !n_ok do continue
            binding := u32(0)
            if b, b_ok := tex["binding"].(json.Float); b_ok do binding = u32(b)
            result.num_samplers = max(result.num_samplers, binding + 1)
            append(&result.textures, engine.Shader_Texture{name = name, binding = binding})
        }
    }

    result.properties = make([dynamic]engine.Shader_Property, context.temp_allocator)
    if ubos, has := root["ubos"].(json.Array); has {
        for entry in ubos {
            ubo, entry_ok := entry.(json.Object)
            if !entry_ok do continue
            binding := u32(0)
            if b, b_ok := ubo["binding"].(json.Float); b_ok do binding = u32(b)
            result.num_uniform_buffers = max(result.num_uniform_buffers, binding + 1)

            if binding != engine.SHADER_MATERIAL_UBO_BINDING do continue
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
                append(&result.properties, engine.Shader_Property{name = name, offset = offset, size = size})
            }
        }
    }
    return result, true
}
