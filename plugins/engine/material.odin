package engine

// Material asset (plugins/engine/docs/Materials.md): picks a shader (built-in
// enum or a custom .glsl asset) and supplies its property block — texture,
// color, and named properties for custom shaders. Materials are JSON files
// under assets/ ("Assets/Create/Material" writes New Material.mat) and
// cached by guid like textures/meshes. MeshRenderer references one by guid;
// no material = plain white, lit on a mesh and unlit on a quad.

import "base:runtime"
import gfx "moonhug:libs/gfx"
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

// Which sides of a mesh's triangles draw. Front is the zero value: the inside
// of a closed mesh is never seen, so its back faces are skipped. Both is for
// open, thin geometry seen from either side: leaves, cloth, planes.
Material_Render_Face :: enum u8 {
	Front,
	Back,
	Both,
}

// Whether a mesh with the material is solid or see-through. Transparent
// draws after every opaque mesh, back to front, blended by its alpha (the
// texture's times the color's, or a surface shader's s.alpha), writes no
// depth, casts no shadow and takes no ambient occlusion or motion vectors.
Material_Surface :: enum u8 {
	Opaque,
	Transparent,
}

// A named value for the custom shader's material UBO (set=3 binding=1).
// Stored as vec4; floats use .x, vec2 .xy, vec3 .xyz — matched to the
// shader's reflected member by name, extra/unknown names are ignored.
Material_Property :: struct {
	name:  string,
	value: [4]f32,
}

// A named texture for the custom shader's extra samplers (set=2, binding 1+;
// binding 0 is Material.texture). Matched to the shader's reflected sampler
// by name; an empty guid binds white.
Material_Texture :: struct {
	name:    string,
	texture: Asset_GUID `ext:"png,jpg,jpeg,bmp"`,
}

@(typ_guid={guid = "4d201ba5-2097-48bb-abd3-1a79e4f6f6f4", menu_assets_create = {menu_name = "Material", file_name = "New Material.mat", order = -6}})
Material :: struct {
	shader:        Material_Shader,
	custom_shader: Asset_GUID `ext:"glsl,shadergraph"`, // user .glsl or .shadergraph asset; overrides `shader` when set
	texture:       Asset_GUID `ext:"png,jpg,jpeg,bmp"`,
	color:         [4]f32 `decor:color()`,
	// Alpha clipping: a pixel whose alpha (the texture's times the color's,
	// or what a surface shader sets) is below alpha_cutoff is not drawn and
	// casts no shadow. For leaves, fences, cutout decals.
	alpha_clip:    bool,
	alpha_cutoff:  f32 `decor:range(0, 1)`,
	// The faces drawn, in every pass, shadows included.
	render_face:   Material_Render_Face,
	surface:       Material_Surface,
	// The built-in Lit's surface. Unlit and custom shaders ignore it.
	lit:           Material_Lit,
	properties:    [dynamic]Material_Property, // custom-shader property block values
	textures:      [dynamic]Material_Texture,  // custom-shader extra sampler assignments
}

// The built-in Lit shader's physically based surface: metal/roughness, the
// model glTF uses, in the terms of the engine's Lit material UX (smoothness,
// not roughness). Each map multiplies its factor, an unassigned map is white.
Material_Lit :: struct {
	metallic:               f32 `decor:range(0, 1)`,
	smoothness:             f32 `decor:range(0, 1)`,
	// glTF packing: green is roughness, blue is metallic.
	metallic_roughness_map: Asset_GUID `ext:"png,jpg,jpeg,bmp"`,
	normal_map:             Asset_GUID `ext:"png,jpg,jpeg,bmp"`,
	normal_scale:           f32 `decor:min(0)`,
	occlusion_map:          Asset_GUID `ext:"png,jpg,jpeg,bmp"`, // red channel
	occlusion_strength:     f32 `decor:range(0, 1)`,
	emission_map:           Asset_GUID `ext:"png,jpg,jpeg,bmp"`,
	emission_color:         [4]f32 `decor:color()`, // brighter than 1 for HDR emission
}

// What a material without a lit block gets: a dielectric of medium
// smoothness, full-strength maps, no emission.
MATERIAL_LIT_DEFAULT :: Material_Lit{smoothness = 0.5, normal_scale = 1, occlusion_strength = 1}

// A new material is Lit. `shader` is stored as a number and
// every saved material carries it, so this changes nothing already written.
reset_Material :: proc(m: ^Material) {
	cleanup_Material(m)
	m.shader = .Lit
	m.color = {1, 1, 1, 1}
	m.alpha_cutoff = MATERIAL_ALPHA_CUTOFF_DEFAULT
	m.lit = MATERIAL_LIT_DEFAULT
}

// The alpha clipping threshold of a new material, and of a file without one.
MATERIAL_ALPHA_CUTOFF_DEFAULT :: 0.5

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
// any load failure falls back to plain white drawn with `fallback`: meshes
// pass Lit, so an unassigned slot is shaded like a default material, quads
// keep Unlit, so a sprite without a material stays flat. material_data (temp-allocated,
// nil when the shader has no property block) is the packed UBO for the
// custom shader's material block; extra_textures (temp-allocated, nil unless
// the custom shader declares samplers past binding 0) holds bindings 1..N —
// nil entries bind white.
// Public resolve for preview/tooling draws (the editor's thumbnails): the
// shader name, bound texture, tint, packed property block and extra textures
// one gfx.draw_quad call needs. The returned slices are cached by the material
// system — do not free.
material_resolve_draw :: proc(guid: Asset_GUID) -> (shader: string, tex: ^gfx.Texture, color: [4]f32, material_data: []u8, extra_textures: []^gfx.Texture) {
	return _resolve_material(guid)
}

// The alpha cutoff a draw of the material passes to gfx.draw_mesh: its
// threshold with alpha clipping on, 0 (nothing clipped) with it off or for no
// material.
material_alpha_cutoff :: proc(guid: Asset_GUID) -> f32 {
	if guid == {} do return 0
	mat, ok := material_load(guid)
	if !ok || !mat.alpha_clip do return 0
	return clamp(mat.alpha_cutoff, 0, 1)
}

// The faces a mesh draw of the material skips (gfx.draw_mesh cull): back
// faces for Front, front faces for Back, none for Both. No material draws
// front faces, as a new material does.
// Whether a draw of the material blends (Material_Surface.Transparent). No
// material, or one that does not load, is opaque.
material_transparent :: proc(guid: Asset_GUID) -> bool {
	if guid == {} do return false
	mat, ok := material_load(guid)
	return ok && mat.surface == .Transparent
}

material_cull :: proc(guid: Asset_GUID) -> gfx.Cull {
	if guid == {} do return .Back
	mat, ok := material_load(guid)
	if !ok do return .Back
	switch mat.render_face {
	case .Front: return .Back
	case .Back:  return .Front
	case .Both:  return .None
	}
	return .Back
}

_resolve_material :: proc(guid: Asset_GUID, fallback := Material_Shader.Unlit) -> (shader: string, tex: ^gfx.Texture, color: [4]f32, material_data: []u8, extra_textures: []^gfx.Texture) {
	shader = material_shader_name(fallback)
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
			extra_textures = _material_resolve_textures(mat, sr)
		}
	}
	if mat.shader == .Lit && mat.custom_shader == {} {
		material_data, extra_textures = _material_pack_lit(&mat.lit)
	}
	color = mat.color
	if mat.texture != {} {
		if t, t_ok := texture_load(mat.texture); t_ok {
			tex = t.gfx
		}
	}
	return
}

// The built-in Lit's material block and maps (surface.glsl LitMaterial):
// bindings 1..4 metallic/roughness, normal, occlusion, emission, white when
// unassigned. A normal scale goes in as 0 without a normal map, since white
// is no normal. The emission color goes in as linear.
_material_pack_lit :: proc(lit: ^Material_Lit) -> (data: []u8, maps: []^gfx.Texture) {
	maps = make([]^gfx.Texture, 4, context.temp_allocator)
	guids := [4]Asset_GUID{lit.metallic_roughness_map, lit.normal_map, lit.occlusion_map, lit.emission_map}
	for g, i in guids {
		if g == {} do continue
		if t, ok := texture_load(g); ok do maps[i] = t.gfx
	}
	normal_scale := maps[1] != nil ? lit.normal_scale : 0
	block := new(gfx.Lit_Material, context.temp_allocator)
	block.params = {clamp(lit.metallic, 0, 1), clamp(lit.smoothness, 0, 1), normal_scale, clamp(lit.occlusion_strength, 0, 1)}
	block.emission = gfx.srgb_to_linear(lit.emission_color)
	data = (^[size_of(gfx.Lit_Material)]u8)(block)[:]
	return
}

// Extra sampler bindings 1..num_samplers-1 for the custom shader
// (temp-allocated; nil when the shader only uses the main texture). Slot i
// holds binding i+1; unassigned/unloadable rows stay nil (white at bind).
_material_resolve_textures :: proc(mat: ^Material, sr: ^Shader_Runtime) -> []^gfx.Texture {
	if sr.num_samplers <= 1 do return nil
	extra := make([]^gfx.Texture, sr.num_samplers - 1, context.temp_allocator)
	for st in sr.textures {
		if st.binding == 0 do continue
		for &mt in mat.textures {
			if mt.name != st.name || mt.texture == {} do continue
			if t, t_ok := texture_load(mt.texture); t_ok {
				extra[st.binding - 1] = t.gfx
			}
			break
		}
	}
	return extra
}

// Whether a shader property is a color: a vec4 whose name says so ("color",
// "colour", any case). The inspector shows it with a color picker, and its
// value, authored in sRGB like every color, reaches the shader as linear.
material_property_is_color :: proc(name: string, size: u32) -> bool {
	if size != 16 do return false
	lower := strings.to_lower(name, context.temp_allocator)
	return strings.contains(lower, "color") || strings.contains(lower, "colour")
}

// Packs Material.properties into the shader's reflected UBO layout
// (temp-allocated; zero-filled for properties the material doesn't set).
// Color properties go in as linear (material_property_is_color).
_material_pack_properties :: proc(mat: ^Material, sr: ^Shader_Runtime) -> []u8 {
	if sr.block_size == 0 do return nil
	data := make([]u8, sr.block_size, context.temp_allocator)
	for sp in sr.properties {
		for &mp in mat.properties {
			if mp.name != sp.name do continue
			value := mp.value
			if material_property_is_color(sp.name, sp.size) do value = gfx.srgb_to_linear(value)
			value_bytes := (^[16]u8)(&value)
			copy(data[sp.offset:], value_bytes[:min(sp.size, 16)])
			break
		}
	}
	return data
}

// Reconciles the material's property AND texture rows with the shader's
// reflected members: missing rows are added (zero-valued/empty), rows whose
// name isn't in the shader are REMOVED — including all of them when
// custom_shader is cleared. The editor calls this for the open material
// every frame, so the inspector always shows exactly the shader's rows. A
// shader that fails to load (compile error, missing toolchain) leaves the
// rows untouched instead of destroying values. Returns true on change.
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
		if len(mat.textures) > 0 {
			for &mt in mat.textures {
				delete(mt.name)
			}
			clear(&mat.textures)
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

	// Texture rows: same reconcile against the reflected samplers, skipping
	// binding 0 (that's Material.texture / the sprite's own texture).
	for i := 0; i < len(mat.textures); {
		found := false
		for st in sr.textures {
			if st.binding != 0 && st.name == mat.textures[i].name {
				found = true
				break
			}
		}
		if found {
			i += 1
			continue
		}
		delete(mat.textures[i].name)
		ordered_remove(&mat.textures, i)
		changed = true
	}
	tex_outer: for st in sr.textures {
		if st.binding == 0 do continue
		for &mt in mat.textures {
			if mt.name == st.name do continue tex_outer
		}
		append(&mat.textures, Material_Texture{name = strings.clone(st.name)})
		changed = true
	}
	return changed
}

material_cache: map[Asset_GUID]Material

// Counts the changes to what a cached material renders as: a live edit
// (material_preview with new values) or an entry dropped (material_unload). A
// picture rendered at one version is current until it moves (the inspector's
// asset previews redraw on change only).
material_cache_version: u64
// Explicit flag: an empty map still compares equal to nil in Odin, so the
// map itself can't distinguish "initialized" from "headless context without
// a cache" (where loads must fail instead of inserting).
_material_cache_ready: bool

material_cache_init :: proc() {
	material_cache = make(map[Asset_GUID]Material)
	_material_cache_ready = true
}

material_cache_shutdown :: proc() {
	context.allocator = runtime.default_allocator()
	for _, &mat in material_cache {
		cleanup_Material(&mat)
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
	context.allocator = runtime.default_allocator() // the cache outlives every caller

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
	context.allocator = runtime.default_allocator()
	if mat, ok := &material_cache[guid]; ok {
		material_cache_version += 1
		cleanup_Material(mat)
		delete_key(&material_cache, guid)
	}
}

// Editor hook: pushes (possibly unsaved) inspector values into the cache so
// material edits render live. Deep-cloned — the inspector owns its instance
// and may free it; skipped when the cache already matches (per-frame call).
// The cache is pinned to the default allocator whatever the caller runs
// under: a clone made with a frame allocator freed later is a bad free.
material_preview :: proc(guid: Asset_GUID, mat: Material) {
	if !_material_cache_ready do return
	context.allocator = runtime.default_allocator()
	if existing, ok := &material_cache[guid]; ok {
		if _material_equal(existing^, mat) do return
		cleanup_Material(existing)
	}
	material_cache[guid] = _material_clone(mat)
	material_cache_version += 1
}

// Cache invalidation for external file changes and removed files, the asset
// database's evict hook (editor saves push values directly via
// material_preview).
@(init)
_material_evict_hook_register :: proc "contextless" () {
	context = runtime.default_context()
	asset_db_add_evict_hook(material_path_changed)
}

material_path_changed :: proc(path: string) {
	if !strings.has_suffix(path, ".mat") do return
	if guid, ok := asset_db_get_guid(path); ok {
		material_unload(Asset_GUID(guid))
	}
}

// Frees what a material owns and leaves it zeroed (plugins/engine/docs/Components.md,
// "Lifecycle procs").
cleanup_Material :: proc(mat: ^Material) {
	for &prop in mat.properties {
		delete(prop.name)
	}
	delete(mat.properties)
	for &tex in mat.textures {
		delete(tex.name)
	}
	delete(mat.textures)
	mat^ = {}
}

_material_clone :: proc(mat: Material) -> Material {
	cloned := mat
	cloned.properties = make([dynamic]Material_Property, 0, len(mat.properties))
	for prop in mat.properties {
		append(&cloned.properties, Material_Property{name = strings.clone(prop.name), value = prop.value})
	}
	cloned.textures = make([dynamic]Material_Texture, 0, len(mat.textures))
	for tex in mat.textures {
		append(&cloned.textures, Material_Texture{name = strings.clone(tex.name), texture = tex.texture})
	}
	return cloned
}

_material_equal :: proc(a, b: Material) -> bool {
	if a.shader != b.shader || a.custom_shader != b.custom_shader || a.texture != b.texture || a.color != b.color || a.lit != b.lit do return false
	if a.alpha_clip != b.alpha_clip || a.alpha_cutoff != b.alpha_cutoff || a.render_face != b.render_face || a.surface != b.surface do return false
	if len(a.properties) != len(b.properties) do return false
	for prop, i in a.properties {
		if prop.name != b.properties[i].name || prop.value != b.properties[i].value do return false
	}
	if len(a.textures) != len(b.textures) do return false
	for tex, i in a.textures {
		if tex.name != b.textures[i].name || tex.texture != b.textures[i].texture do return false
	}
	return true
}

// The serializer writes {"__type_guid": ..., fields...}; unmarshal ignores
// the unknown key. Fields absent from the file keep the defaults set here.
// Allocates with context.allocator (properties live in the cache).
_material_parse :: proc(data: []byte) -> (Material, bool) {
	// The same defaults as reset_Material, for a hand-written file that
	// leaves a field out.
	mat := Material{shader = .Lit, color = {1, 1, 1, 1}, alpha_cutoff = MATERIAL_ALPHA_CUTOFF_DEFAULT, lit = MATERIAL_LIT_DEFAULT}
	if json.unmarshal(data, &mat, .JSON, context.allocator) != nil {
		cleanup_Material(&mat)
		return {}, false
	}
	return mat, true
}
