package engine

// Unity-style Material asset (docs/Materials.md): picks a built-in shader and
// supplies its property block — texture + color for now. Materials are JSON
// files under assets/ ("Assets/Create/Material" writes New Material.mat) and
// cached by guid like textures/meshes. MeshRenderer references one by guid;
// no material = plain white unlit (mirrors Unity's missing-material magenta,
// minus the drama).

import gfx "gfx"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:os"
import "core:strings"

// Built-in shaders only — a fixed enum keeps Material free of string
// ownership and gives the inspector a dropdown. The gfx side is name-keyed
// (gfx.shader_register), so user-authored shaders later mean widening this
// mapping, not reworking the renderer.
Material_Shader :: enum u8 {
	Unlit,
	Lit,
}

@(typ_guid={guid = "4d201ba5-2097-48bb-abd3-1a79e4f6f6f4", makeProcName=make_pMaterial, menu_assets_create = {menu_name = "Material", file_name = "New Material.mat", order = -6}})
Material :: struct {
	shader:  Material_Shader,
	texture: Asset_GUID `ext:"png,jpg,jpeg,bmp"`,
	color:   [4]f32 `decor:color()`,
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
// any load failure falls back to white unlit.
_resolve_material :: proc(guid: Asset_GUID) -> (shader: string, tex: ^gfx.Texture, color: [4]f32) {
	shader = material_shader_name(.Unlit)
	color = {1, 1, 1, 1}
	if guid == {} do return
	mat, ok := material_load(guid)
	if !ok do return
	shader = material_shader_name(mat.shader)
	color = mat.color
	if mat.texture != {} {
		if t, t_ok := texture_load(mat.texture); t_ok {
			tex = t.gfx
		}
	}
	return
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
	delete_key(&material_cache, guid)
}

// Editor hook: pushes (possibly unsaved) inspector values into the cache so
// material edits render live. Material is plain data — a value copy suffices.
material_preview :: proc(guid: Asset_GUID, mat: Material) {
	if !_material_cache_ready do return
	material_cache[guid] = mat
}

// Cache invalidation for external file changes, called from asset_db_refresh
// (editor saves push values directly via material_preview).
material_path_changed :: proc(path: string) {
	if !strings.has_suffix(path, ".mat") do return
	if guid, ok := asset_db_get_guid(path); ok {
		material_unload(Asset_GUID(guid))
	}
}

// The serializer writes {"__type_guid": ..., fields...}; unmarshal ignores
// the unknown key. Fields absent from the file keep the defaults set here.
_material_parse :: proc(data: []byte) -> (Material, bool) {
	mat := Material{color = {1, 1, 1, 1}}
	if json.unmarshal(data, &mat, .JSON, context.temp_allocator) != nil {
		return {}, false
	}
	return mat, true
}
