package engine

// Unity-style Material asset (docs/Materials.md): picks a shader (built-in
// enum or a custom .glsl asset) and supplies its property block — texture,
// color, and named properties for custom shaders. Materials are JSON files
// under assets/ ("Assets/Create/Material" writes New Material.mat) and
// cached by guid like textures/meshes. MeshRenderer references one by guid;
// no material = plain white unlit (mirrors Unity's missing-material magenta,
// minus the drama).

import gfx "gfx"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:os"
import "core:strings"

// Built-in shaders — a fixed enum keeps the common case dropdown-simple.
// Custom .glsl shaders come in through Material.custom_shader instead.
Material_Shader :: enum u8 {
	Unlit,
	Lit,
}

// A named value for the custom shader's material UBO (set=3 binding=1).
// Stored as vec4; floats use .x, vec2 .xy, vec3 .xyz — matched to the
// shader's reflected member by name, extra/unknown names are ignored.
Material_Property :: struct {
	name:  string,
	value: [4]f32,
}

@(typ_guid={guid = "4d201ba5-2097-48bb-abd3-1a79e4f6f6f4", makeProcName=make_pMaterial, menu_assets_create = {menu_name = "Material", file_name = "New Material.mat", order = -6}})
Material :: struct {
	shader:        Material_Shader,
	custom_shader: Asset_GUID `ext:"glsl"`, // user .glsl asset; overrides `shader` when set
	texture:       Asset_GUID `ext:"png,jpg,jpeg,bmp"`,
	color:         [4]f32 `decor:color()`,
	properties:    [dynamic]Material_Property, // custom-shader property block values
}

make_pMaterial :: proc() -> any {
	m := new(Material)
	m.color = {1, 1, 1, 1}
	return m^
}

// gfx shader-set name for draw_mesh. Returned strings are literals — safe to
// hold in draw commands across the frame.
material_shader_name :: proc(shader: Material_Shader) -> string {
	switch shader {
	case .Unlit: return "unlit"
	case .Lit:   return "lit"
	}
	return "unlit"
}

// Resolves a material guid to draw state for gfx.draw_mesh. Empty guid or
// any load failure falls back to white unlit. material_data (temp-allocated,
// nil when the shader has no property block) is the packed UBO for the
// custom shader's material block.
_resolve_material :: proc(guid: Asset_GUID) -> (shader: string, tex: ^gfx.Texture, color: [4]f32, material_data: []u8) {
	shader = material_shader_name(.Unlit)
	color = {1, 1, 1, 1}
	if guid == {} do return
	mat, ok := material_load(guid)
	if !ok do return
	shader = material_shader_name(mat.shader)
	if mat.custom_shader != {} {
		// Unresolvable custom shader (missing toolchain, compile error) keeps
		// the built-in fallback instead of dropping the draw.
		if sr, sr_ok := shader_load(mat.custom_shader); sr_ok {
			shader = sr.name
			material_data = _material_pack_properties(mat, sr)
		}
	}
	color = mat.color
	if mat.texture != {} {
		if t, t_ok := texture_load(mat.texture); t_ok {
			tex = t.gfx
		}
	}
	return
}

// Packs Material.properties into the shader's reflected UBO layout
// (temp-allocated; zero-filled for properties the material doesn't set).
_material_pack_properties :: proc(mat: ^Material, sr: ^Shader_Runtime) -> []u8 {
	if sr.block_size == 0 do return nil
	data := make([]u8, sr.block_size, context.temp_allocator)
	for sp in sr.properties {
		for &mp in mat.properties {
			if mp.name != sp.name do continue
			value := mp.value
			value_bytes := (^[16]u8)(&value)
			copy(data[sp.offset:], value_bytes[:min(sp.size, 16)])
			break
		}
	}
	return data
}

// Reconciles the material's property rows with the shader's reflected
// members: missing rows are added (zero-valued), rows whose name isn't in
// the shader are REMOVED — including all of them when custom_shader is
// cleared. The editor calls this for the open material every frame, so the
// inspector always shows exactly the shader's properties. A shader that
// fails to load (compile error, missing toolchain) leaves the rows
// untouched instead of destroying values. Returns true on change.
material_sync_properties :: proc(mat: ^Material) -> bool {
	changed := false
	if mat.custom_shader == {} {
		if len(mat.properties) > 0 {
			for &mp in mat.properties {
				delete(mp.name)
			}
			clear(&mat.properties)
			changed = true
		}
		return changed
	}
	sr, ok := shader_load(mat.custom_shader)
	if !ok do return false

	for i := 0; i < len(mat.properties); {
		found := false
		for sp in sr.properties {
			if sp.name == mat.properties[i].name {
				found = true
				break
			}
		}
		if found {
			i += 1
			continue
		}
		delete(mat.properties[i].name)
		ordered_remove(&mat.properties, i)
		changed = true
	}
	outer: for sp in sr.properties {
		for &mp in mat.properties {
			if mp.name == sp.name do continue outer
		}
		append(&mat.properties, Material_Property{name = strings.clone(sp.name)})
		changed = true
	}
	return changed
}

material_cache: map[Asset_GUID]Material
// Explicit flag: an empty map still compares equal to nil in Odin, so the
// map itself can't distinguish "initialized" from "headless context without
// a cache" (where loads must fail instead of inserting).
_material_cache_ready: bool

material_cache_init :: proc() {
	material_cache = make(map[Asset_GUID]Material)
	_material_cache_ready = true
}

material_cache_shutdown :: proc() {
	for _, &mat in material_cache {
		_material_destroy(&mat)
	}
	delete(material_cache)
	material_cache = nil
	_material_cache_ready = false
}

// Materials hold no GPU resources, so unlike texture/mesh loads this works
// headless — but only in contexts that initialized the cache.
material_load :: proc(guid: Asset_GUID) -> (^Material, bool) {
	if mat, ok := &material_cache[guid]; ok {
		return mat, true
	}
	if !_material_cache_ready do return nil, false

	path, path_ok := asset_db_get_path(uuid.Identifier(guid))
	if !path_ok do return nil, false
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil do return nil, false

	mat, parse_ok := _material_parse(data)
	if !parse_ok do return nil, false
	material_cache[guid] = mat
	return &material_cache[guid], true
}

material_unload :: proc(guid: Asset_GUID) {
	if mat, ok := &material_cache[guid]; ok {
		_material_destroy(mat)
		delete_key(&material_cache, guid)
	}
}

// Editor hook: pushes (possibly unsaved) inspector values into the cache so
// material edits render live. Deep-cloned — the inspector owns its instance
// and may free it; skipped when the cache already matches (per-frame call).
material_preview :: proc(guid: Asset_GUID, mat: Material) {
	if !_material_cache_ready do return
	if existing, ok := &material_cache[guid]; ok {
		if _material_equal(existing^, mat) do return
		_material_destroy(existing)
	}
	material_cache[guid] = _material_clone(mat)
}

// Cache invalidation for external file changes, called from asset_db_refresh
// (editor saves push values directly via material_preview).
material_path_changed :: proc(path: string) {
	if !strings.has_suffix(path, ".mat") do return
	if guid, ok := asset_db_get_guid(path); ok {
		material_unload(Asset_GUID(guid))
	}
}

_material_destroy :: proc(mat: ^Material) {
	for &prop in mat.properties {
		delete(prop.name)
	}
	delete(mat.properties)
	mat^ = {}
}

_material_clone :: proc(mat: Material) -> Material {
	cloned := mat
	cloned.properties = make([dynamic]Material_Property, 0, len(mat.properties))
	for prop in mat.properties {
		append(&cloned.properties, Material_Property{name = strings.clone(prop.name), value = prop.value})
	}
	return cloned
}

_material_equal :: proc(a, b: Material) -> bool {
	if a.shader != b.shader || a.custom_shader != b.custom_shader || a.texture != b.texture || a.color != b.color do return false
	if len(a.properties) != len(b.properties) do return false
	for prop, i in a.properties {
		if prop.name != b.properties[i].name || prop.value != b.properties[i].value do return false
	}
	return true
}

// The serializer writes {"__type_guid": ..., fields...}; unmarshal ignores
// the unknown key. Fields absent from the file keep the defaults set here.
// Allocates with context.allocator (properties live in the cache).
_material_parse :: proc(data: []byte) -> (Material, bool) {
	mat := Material{color = {1, 1, 1, 1}}
	if json.unmarshal(data, &mat, .JSON, context.allocator) != nil {
		_material_destroy(&mat)
		return {}, false
	}
	return mat, true
}
