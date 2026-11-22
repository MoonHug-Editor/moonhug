package importers

// User shader importer (plugins/engine/docs/Materials.md). A `.glsl` asset is a FRAGMENT
// shader only — the vertex stage is always the built-in world vertex shader.
// Import shells out to the same toolchain as `mh shaders` (glslc →
// SPIR-V, spirv-cross → MSL + reflection) and caches both blobs in the
// artifact; contributors WITHOUT the toolchain can still open the project —
// only authoring/editing shaders needs `brew install shaderc spirv-cross`.
// The artifact FORMAT and its parse live in the engine
// (asset_importer_shader.odin) — runtime shader loading reads them.

import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"
import "base:runtime"
import "moonhug:libs/assets"
import "moonhug:packages/engine"
import gfx "moonhug:libs/gfx"
import "moonhug:libs/log"

_import_shader :: proc(source_path: string, artifact_path: string, settings: rawptr) -> bool {
    source, read_err := os.read_entire_file(source_path, context.temp_allocator)
    if read_err != nil {
        log.errorf("[Pipeline] Cannot read shader source: %s", source_path)
        return false
    }
    return shader_compile_source(string(source), source_path, artifact_path)
}

// Compiles fragment shader GLSL to the shader artifact at `artifact_path`:
// a surface shader (surface() and no main()) wrapped in the template, any
// other source as it is. `source_path` names the source in messages and
// is where the assembled file sits when the source is not a file of its own
// (a generated shader passes its asset's path). The .glsl importer and the
// shader graph importer both end here.
shader_compile_source :: proc(source: string, source_path: string, artifact_path: string) -> bool {
    tmp_spv := strings.concatenate({artifact_path, ".spv.tmp"}, context.temp_allocator)
    tmp_msl := strings.concatenate({artifact_path, ".msl.tmp"}, context.temp_allocator)
    tmp_json := strings.concatenate({artifact_path, ".json.tmp"}, context.temp_allocator)
    defer os.remove(tmp_spv)
    defer os.remove(tmp_msl)
    defer os.remove(tmp_json)

    engine._ensure_artifact_dir(artifact_path)

    // A surface shader (surface() and no main()) compiles wrapped in the
    // template, see _surface_assemble. Any other source compiles from a copy
    // next to the artifact, so a generated shader needs no file of its own.
    // `compile_path` is what glslc reads.
    compile_path: string
    auto_clip := engine.ui_mask_shader_clip() == .Auto_Inject
    // The UI clip include a plain shader compiles with is gone again after
    // the compile: the folder is only glslc's.
    defer if !_is_surface_shader(source) {
        dir := _surface_include_dir(artifact_path)
        os.remove(strings.concatenate({dir, "/ui_clip.glsl"}, context.temp_allocator))
        os.remove(dir)
    }
    if _is_surface_shader(source) {
        assembled, ok := _surface_assemble(source, artifact_path)
        if !ok do return false
        compile_path = assembled
    } else {
        // The UI clip include sits beside the artifact for `#include
        // "ui_clip.glsl"`, written by hand or added here (shader_inject_clip).
        if !_write_include(artifact_path, "ui_clip.glsl", gfx.UI_CLIP_GLSL) do return false
        text := source
        if auto_clip {
            injected, why := shader_inject_clip(source)
            if why != "" {
                log.errorf("[Pipeline] %s: %s. The project's UiMask setting is Auto Inject (Project Settings, UiMask)", source_path, why)
                return false
            }
            text = injected
        }
        compile_path = strings.concatenate({artifact_path, _SURFACE_TMP_SUFFIX}, context.temp_allocator)
        if os.write_entire_file(compile_path, transmute([]u8)text) != nil do return false
    }
    // With Auto Inject a ui_clip() written by hand is 1 (ui_clip.glsl).
    clip_define := "-DMOONHUG_UI_CLIP_AUTO" if auto_clip else "-DMOONHUG_UI_CLIP_MANUAL"
    tmp_assembled := strings.concatenate({artifact_path, _SURFACE_TMP_SUFFIX}, context.temp_allocator)
    defer os.remove(tmp_assembled)

    // Input file FIRST for spirv-cross: --reflect greedily consumes a
    // following bare argument as its optional format, eating the input path.
    // --msl-decoration-binding: keep GLSL binding numbers as Metal buffer
    // indices — by default spirv-cross assigns them SEQUENTIALLY, so a lone
    // MaterialUBO at binding=1 would land at buffer(0) while the engine
    // pushes property data to slot 1 (silently reading the light UBO).
    // -I: the surface template's include folder, next to the artifact.
    if !_run_tool({"glslc", "-fshader-stage=frag", clip_define, "-I", _surface_include_dir(artifact_path), compile_path, "-o", tmp_spv}, source_path) do return false
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

    // A surface shader's caster: the same surface() in the template's
    // depth-pass main, what depth passes (shadow casters, the depth prepass)
    // draw an alpha-clipped material with.
    caster_spv, caster_msl: []u8
    caster_reflect: _Shader_Reflect
    if _is_surface_shader(source) {
        ok: bool
        caster_spv, caster_msl, caster_reflect, ok = _compile_caster(source, source_path, artifact_path)
        if !ok do return false
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
        caster_spv_len         = u32(len(caster_spv)),
        caster_msl_len         = u32(len(caster_msl)),
        caster_samplers        = caster_reflect.num_samplers,
        caster_uniform_buffers = caster_reflect.num_uniform_buffers,
    }
    copy(header.magic[:], engine.SHADER_ARTIFACT_MAGIC)

    blob := make([dynamic]u8, 0, size_of(header) + len(spv) + len(msl) + 256, context.temp_allocator)
    header_bytes := (^[size_of(engine.Shader_Artifact_Header)]u8)(&header)
    append(&blob, ..header_bytes[:])
    append(&blob, ..spv)
    append(&blob, ..msl)
    append(&blob, ..caster_spv)
    append(&blob, ..caster_msl)
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

// --- Surface shaders --------------------------------------------------------

// The shader importer's version: 1 plus a hash of the surface template, so
// an artifact compiled against an older template reimports (the artifact
// key hashes the importer version).
shader_compile_version :: 3
shader_importer_version :: proc() -> int {
	h := hash.fnv32a(transmute([]u8)gfx.SURFACE_GLSL)
	h = hash.fnv32a(transmute([]u8)gfx.SURFACE_MAIN_GLSL, h)
	// The UI clip include and the project's UiMask setting are inputs of
	// every plain fragment shader too.
	h = hash.fnv32a(transmute([]u8)gfx.UI_CLIP_GLSL, h)
	mode := [1]u8{u8(engine.ui_mask_shader_clip())}
	h = hash.fnv32a(mode[:], h)
	return shader_compile_version * 1_000_000 + int(h % 1_000_000)
}

// The extensions whose importer compiles through shader_compile_source: .glsl
// here, and what another plugin's importer adds (the shader graph's). A
// change of what every shader compiles with reimports them
// (shaders_reimport_all).
@(private = "file")
_shader_source_exts: [dynamic]string

shader_source_ext_add :: proc(ext: string) {
	context.allocator = runtime.default_allocator()
	for e in _shader_source_exts do if e == ext do return
	append(&_shader_source_exts, strings.clone(ext))
}

// Compiles every shader of the project again, now: after the project's
// UiMask setting changed, which is an input of each. Returns how many.
shaders_reimport_all :: proc() -> (count: int) {
	shader_source_ext_add(".glsl")
	paths := make([dynamic]string, context.temp_allocator)
	for path, _ in assets.asset_db.path_to_guid {
		for ext in _shader_source_exts do if strings.has_suffix(path, ext) {
			append(&paths, path)
			break
		}
	}
	for path in paths {
		if guid, ok := engine.asset_db_get_guid(path); ok do engine.shader_unload(engine.Asset_GUID(guid))
		if engine.asset_pipeline_request_import(path, true) do count += 1
	}
	return
}

// One of the engine's include files into the folder glslc looks in.
@(private = "file")
_write_include :: proc(artifact_path: string, name: string, text: string) -> bool {
	dir := _surface_include_dir(artifact_path)
	os.make_directory_all(dir)
	path := strings.concatenate({dir, "/", name}, context.temp_allocator)
	return os.write_entire_file(path, transmute([]u8)text) == nil
}

// The name the importer gives a shader's own main() when it adds the UI clip.
SHADER_USER_MAIN :: "moonhug_user_main"

// A fragment shader's source with the UI clip added (the project's UiMask
// setting on Auto Inject): its main() renamed, and after its code a main()
// that runs it and multiplies the alpha of its output by the clip. Every
// line of the source keeps its number. `why` says what stopped it:
// - no `void main(`, or more than one: nothing to wrap.
// - no `layout(location = 0) out vec4 name;`: no output to clip.
shader_inject_clip :: proc(source: string, allocator := context.temp_allocator) -> (out: string, why: string) {
	// The one `void main(`, outside of comments.
	code := _strip_comments(source)
	at := -1
	for from := 0; true; /**/ {
		i := strings.index(code[from:], "main")
		if i < 0 do break
		i += from
		from = i + 4
		before_ok := i == 0 || !_ident_char(code[i - 1])
		// `void` before it and `(` after it, across spaces.
		k := i + 4
		for k < len(code) && (code[k] == ' ' || code[k] == '\t' || code[k] == '\n' || code[k] == '\r') do k += 1
		is_call := k < len(code) && code[k] == '('
		j := i - 1
		for j >= 0 && (code[j] == ' ' || code[j] == '\t' || code[j] == '\n' || code[j] == '\r') do j -= 1
		is_void := j >= 3 && code[j - 3:j + 1] == "void" && (j == 3 || !_ident_char(code[j - 4]))
		if !before_ok || !is_call || !is_void do continue
		if at >= 0 do return "", "the shader has more than one main(), the UI clip cannot wrap it"
		at = i
	}
	if at < 0 do return "", "the shader has no `void main(`, the UI clip cannot wrap it"
	output := _output_name(code)
	if output == "" do return "", "the shader has no `layout(location = 0) out vec4 <name>;`, the UI clip has no output to clip"

	b := strings.builder_make(allocator)
	strings.write_string(&b, source[:at])
	strings.write_string(&b, SHADER_USER_MAIN)
	strings.write_string(&b, source[at + 4:])
	strings.write_string(&b, "\n\n// Added by the shader importer: the UI clip (Project Settings, UiMask: Auto Inject).\n")
	strings.write_string(&b, "#include \"ui_clip.glsl\"\nvoid main() {\n    ")
	strings.write_string(&b, SHADER_USER_MAIN)
	strings.write_string(&b, "();\n    ")
	strings.write_string(&b, output)
	strings.write_string(&b, ".a *= ui_clip_at(gl_FragCoord.xy);\n}\n")
	return strings.to_string(b), ""
}

@(private = "file")
_ident_char :: proc(c: u8) -> bool {
	return c == '_' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

// The source with its comments turned to spaces, every other character where
// it was: a `main` in a comment is no main, and an offset here is an offset
// in the source.
@(private = "file")
_strip_comments :: proc(source: string) -> string {
	out := make([]u8, len(source), context.temp_allocator)
	copy(out, source)
	for i := 0; i + 1 < len(out); i += 1 {
		if out[i] == '/' && out[i + 1] == '/' {
			for i < len(out) && out[i] != '\n' {
				out[i] = ' '
				i += 1
			}
		} else if out[i] == '/' && out[i + 1] == '*' {
			for i + 1 < len(out) && !(out[i] == '*' && out[i + 1] == '/') {
				if out[i] != '\n' do out[i] = ' '
				i += 1
			}
			if i + 1 < len(out) {
				out[i], out[i + 1] = ' ', ' '
				i += 1
			}
		}
	}
	return string(out)
}

// The name of the vec4 output at location 0, "" for none.
@(private = "file")
_output_name :: proc(code: string) -> string {
	rest := code
	for {
		i := strings.index(rest, "layout")
		if i < 0 do return ""
		rest = rest[i + len("layout"):]
		semi := strings.index_byte(rest, ';')
		if semi < 0 do return ""
		decl := rest[:semi]
		close := strings.index_byte(decl, ')')
		if close < 0 do continue
		// `( location = 0 )`, spaces anywhere.
		inside, _ := strings.remove_all(decl[:close], " ", context.temp_allocator)
		inside, _ = strings.remove_all(inside, "\t", context.temp_allocator)
		if inside != "(location=0" do continue
		words := strings.fields(decl[close + 1:], context.temp_allocator)
		if len(words) == 3 && words[0] == "out" && words[1] == "vec4" do return words[2]
	}
}

_SURFACE_TMP_SUFFIX :: ".surface.glsl.tmp"
_CASTER_TMP_SUFFIX  :: ".caster.glsl.tmp"

// A surface shader's caster variant: SPIR-V, MSL and its reflected resource
// counts (temp-allocated). Its errors are the main variant's, which compiled
// first, so a failure here is reported the same way.
_compile_caster :: proc(source, source_path, artifact_path: string) -> (spv, msl: []u8, reflect: _Shader_Reflect, ok: bool) {
    assembled := _surface_assemble(source, artifact_path, caster = true) or_return
    defer os.remove(assembled)
    tmp_spv := strings.concatenate({artifact_path, ".caster.spv.tmp"}, context.temp_allocator)
    tmp_msl := strings.concatenate({artifact_path, ".caster.msl.tmp"}, context.temp_allocator)
    tmp_json := strings.concatenate({artifact_path, ".caster.json.tmp"}, context.temp_allocator)
    defer os.remove(tmp_spv)
    defer os.remove(tmp_msl)
    defer os.remove(tmp_json)
    _run_tool({"glslc", "-fshader-stage=frag", "-I", _surface_include_dir(artifact_path), assembled, "-o", tmp_spv}, source_path) or_return
    _run_tool({"spirv-cross", tmp_spv, "--msl", "--msl-decoration-binding", "--output", tmp_msl}, source_path) or_return
    _run_tool({"spirv-cross", tmp_spv, "--reflect", "--output", tmp_json}, source_path) or_return
    spv_err, msl_err, json_err: os.Error
    reflect_data: []u8
    spv, spv_err = os.read_entire_file(tmp_spv, context.temp_allocator)
    msl, msl_err = os.read_entire_file(tmp_msl, context.temp_allocator)
    reflect_data, json_err = os.read_entire_file(tmp_json, context.temp_allocator)
    if spv_err != nil || msl_err != nil || json_err != nil {
        log.errorf("[Pipeline] Shader tool output missing for the caster: %s", source_path)
        return
    }
    reflect, ok = _shader_reflect(reflect_data)
    if !ok do log.errorf("[Pipeline] Failed to parse the caster's reflection: %s", source_path)
    return
}

// A surface shader declares surface() and leaves main() to the template.
_is_surface_shader :: proc(source: string) -> bool {
    return strings.contains(source, "void surface(") && !strings.contains(source, "void main(")
}

// Where the template's include files sit for glslc: a folder next to the
// artifact, rewritten on every import so an engine update reaches it.
_surface_include_dir :: proc(artifact_path: string) -> string {
    return strings.concatenate({artifact_path, ".inc"}, context.temp_allocator)
}

// The user's surface shader between the template's two halves, as a file for
// glslc. `#line 1` keeps the compiler's error lines pointing at the user's
// file, and the include files come from gfx (the engine's own copy, so the
// template a user shader compiles against is the one the built-in lit shader
// was compiled with). `caster` assembles the depth-pass variant.
_surface_assemble :: proc(source: string, artifact_path: string, caster := false) -> (path: string, ok: bool) {
    dir := _surface_include_dir(artifact_path)
    os.make_directory_all(dir)
    inc := strings.concatenate({dir, "/surface.glsl"}, context.temp_allocator)
    inc_main := strings.concatenate({dir, "/surface_main.glsl"}, context.temp_allocator)
    if os.write_entire_file(inc, transmute([]u8)gfx.SURFACE_GLSL) != nil do return "", false
    if os.write_entire_file(inc_main, transmute([]u8)gfx.SURFACE_MAIN_GLSL) != nil do return "", false

    b := strings.builder_make(context.temp_allocator)
    strings.write_string(&b, "#version 450\n")
    if caster do strings.write_string(&b, "#define MOONHUG_CASTER\n")
    strings.write_string(&b, "#include \"surface.glsl\"\n#line 1\n")
    strings.write_string(&b, source)
    strings.write_string(&b, "\n#include \"surface_main.glsl\"\n")
    path = strings.concatenate({artifact_path, caster ? _CASTER_TMP_SUFFIX : _SURFACE_TMP_SUFFIX}, context.temp_allocator)
    if os.write_entire_file(path, transmute([]u8)strings.to_string(b)) != nil do return "", false
    return path, true
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
            // The surface template's shadow map: gfx binds it, it is no
            // material row.
            // The template's reserved samplers, bound by gfx, never a material row.
            if name == "shadow_map" && binding == gfx.SHADOW_SAMPLER_SLOT do continue
            if name == "env_specular" && binding == gfx.ENV_SPECULAR_SLOT do continue
            if name == "env_irradiance" && binding == gfx.ENV_IRRADIANCE_SLOT do continue
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
