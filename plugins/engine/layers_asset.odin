package engine

// The layer names assets: Render_Layers names the 32 render layers,
// Physics_Layers names the 32 collision layers (plugins/engine/docs/Layers.md).
// Both are plain .asset files.
//
// The Layers project setting names the two assets the project uses
// (Layers_Settings). An unset field is the essentials plugin's default asset
// of that type, and the built-in names of the type's reset when that is not
// installed either.
//
// The engine keeps one copy of each active asset's names and registers the
// copies as the "render" and "physics" layer domains, once. The registry's
// lists never move: a switch to another asset, a change of the file on disk
// and an edit in the inspector all rewrite a copy in place, so the layer
// picker always shows the current asset's names.

import "base:runtime"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:os"
import "core:strings"
import "moonhug:libs/log"

// The names of the 32 render layers. An empty name is an unused layer.
// Layer 31 is the editor's own and the picker does not list it.
@(typ_guid={guid = "61bc7a2f-3326-4f13-b233-7bccf12f709e", menu_assets_create = {menu_name = "Render Layers", file_name = "RenderLayers.asset", order = -3}})
Render_Layers :: struct {
	names: [LAYER_COUNT]string,
}

// The names of the 32 collision layers, one list for the 2D and the 3D
// colliders. An empty name is an unused layer.
@(typ_guid={guid = "e10c4a7e-21cc-4f77-a787-6eb0e1090636", menu_assets_create = {menu_name = "Physics Layers", file_name = "PhysicsLayers.asset", order = -3}})
Physics_Layers :: struct {
	names: [LAYER_COUNT]string,
}

// The layer domain of the render layers: Transform.render_layer and the
// camera, light and probe masks.
LAYER_DOMAIN_RENDER :: "render"
// The layer domain of the collision layers: the `layer` and `mask` of the
// physics2d and physics3d colliders.
LAYER_DOMAIN_PHYSICS :: "physics"

// A new Render Layers asset, and the render names a project has when no asset
// is installed: layer 0 "Default", layer 31 "Editor".
reset_Render_Layers :: proc(l: ^Render_Layers) {
	cleanup_Render_Layers(l)
	l.names[RENDER_LAYER_DEFAULT] = strings.clone("Default")
	l.names[RENDER_LAYER_EDITOR] = strings.clone("Editor")
}

cleanup_Render_Layers :: proc(l: ^Render_Layers) {
	for s in l.names do delete(s)
	l^ = {}
}

// A new Physics Layers asset, and the physics names a project has when no
// asset is installed: layer 0 "Default".
reset_Physics_Layers :: proc(l: ^Physics_Layers) {
	cleanup_Physics_Layers(l)
	l.names[0] = strings.clone("Default")
}

cleanup_Physics_Layers :: proc(l: ^Physics_Layers) {
	for s in l.names do delete(s)
	l^ = {}
}

// The Layers project setting: which Render Layers and which Physics Layers
// asset the project uses. A zero guid is the essentials plugin's default
// asset of that type.
Layers_Settings :: struct {
	render_layers:  Asset_GUID `ref:"Render_Layers"`,
	physics_layers: Asset_GUID `ref:"Physics_Layers"`,
}

@(project_settings={name="Layers"})
layers_settings: Layers_Settings

// Loads ProjectSettings/layers.json into layers_settings, once per engine run.
layers_settings_ensure_loaded :: proc() {
	if _layers_settings_loaded do return
	_layers_settings_loaded = true
	project_settings_load("Layers", &layers_settings)
}

// The assets a project uses when its Layers setting names none: the
// essentials plugin sets them to its default assets at EngineInit. Empty =
// the built-in names.
render_layers_default: Asset_GUID
physics_layers_default: Asset_GUID

// Reads a Render Layers or Physics Layers file. A field the file lacks keeps
// its reset default. A file of another type does not load.
layers_load_file :: proc(path: string, $T: typeid) -> (l: T, ok: bool) where T == Render_Layers || T == Physics_Layers {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return {}, false
	return layers_parse(data, T)
}

layers_parse :: proc(data: []u8, $T: typeid) -> (l: T, ok: bool) where T == Render_Layers || T == Physics_Layers {
	Header :: struct {
		type_guid: string `json:"__type_guid"`,
	}
	h: Header
	if json.unmarshal(data, &h, allocator = context.temp_allocator) != nil do return {}, false
	id, id_err := uuid.read(h.type_guid)
	if id_err != nil || id != get_guid_by_typeid(T) do return {}, false
	if unmarshal_over_reset(data, &l, typeid_of(T)) != nil {
		for s in l.names do delete(s)
		return {}, false
	}
	return l, true
}

// One domain's copy of the active asset's names, on the default allocator.
// The layer registry holds a pointer to `names`.
@(private = "file")
_Domain :: struct {
	names:  [LAYER_COUNT]string,
	guid:   Asset_GUID,
	loaded: bool,
}

@(private = "file") _render: _Domain
@(private = "file") _physics: _Domain
@(private = "file") _layers_settings_loaded: bool

@(init)
_layers_register :: proc "contextless" () {
	context = runtime.default_context()
	_domain_reset(&_render, Render_Layers)
	_domain_reset(&_physics, Physics_Layers)
	layer_domain_register(LAYER_DOMAIN_RENDER, &_render.names, hidden = 1 << RENDER_LAYER_EDITOR)
	layer_domain_register(LAYER_DOMAIN_PHYSICS, &_physics.names)
	asset_db_add_evict_hook(_layers_path_changed)
}

// The Render Layers and Physics Layers assets the project uses now: the
// Layers setting's, else the installed defaults, else {} for the built-in
// names.
layers_active_guids :: proc() -> (render, physics: Asset_GUID) {
	layers_settings_ensure_loaded()
	return _pick(layers_settings.render_layers, render_layers_default), _pick(layers_settings.physics_layers, physics_layers_default)
}

@(private = "file")
_pick :: proc(set, fallback: Asset_GUID) -> Asset_GUID {
	if set != {} do return set
	if fallback == {} do return {}
	if _, installed := asset_db_get_path(uuid.Identifier(fallback)); installed do return fallback
	return {}
}

// Brings the registered names up to date with the assets the Layers setting
// names. A cheap check when nothing changed. The frame calls it
// (render_pipeline_active), and so can code that reads names before the first
// frame.
layers_sync :: proc() {
	context.allocator = runtime.default_allocator()
	render, physics := layers_active_guids()
	_domain_sync(&_render, render, Render_Layers)
	_domain_sync(&_physics, physics, Physics_Layers)
}

@(private = "file")
_domain_sync :: proc(d: ^_Domain, want: Asset_GUID, $T: typeid) {
	if d.loaded && d.guid == want do return
	d.loaded = true
	d.guid = want
	src: T
	ok: bool
	if want != {} {
		if path, has := asset_db_get_path(uuid.Identifier(want)); has do src, ok = layers_load_file(path, T)
	}
	if !ok {
		if want != {} do log.warningf("[Layers] the Layers setting names no readable %v asset, using the built-in names", typeid_of(T))
		_reset(&src)
	}
	defer _cleanup(&src)
	_copy_names(&d.names, src.names)
}

// Editor hooks: a Render Layers or Physics Layers document's current values
// replace the registered names when it is the asset the project uses, so an
// edit in the inspector reaches the layer picker before it is saved.
render_layers_preview :: proc(guid: Asset_GUID, l: Render_Layers) {
	context.allocator = runtime.default_allocator()
	layers_sync()
	if guid != _render.guid do return
	_copy_names(&_render.names, l.names)
}

physics_layers_preview :: proc(guid: Asset_GUID, l: Physics_Layers) {
	context.allocator = runtime.default_allocator()
	layers_sync()
	if guid != _physics.guid do return
	_copy_names(&_physics.names, l.names)
}

// An asset file changed on disk or went away: the domain that uses it reloads
// on the next sync.
@(private = "file")
_layers_path_changed :: proc(path: string) {
	if !strings.has_suffix(path, ".asset") do return
	guid, ok := asset_db_get_guid(path)
	if !ok do return
	for d in ([]^_Domain{&_render, &_physics}) {
		if d.loaded && d.guid == Asset_GUID(guid) do d.loaded = false
	}
}

// The next sync reads the setting and the assets again. The registered names
// stay as they are.
_layers_shutdown :: proc() {
	_layers_settings_loaded = false
	_render.loaded = false
	_render.guid = {}
	_physics.loaded = false
	_physics.guid = {}
}

@(private = "file")
_domain_reset :: proc(d: ^_Domain, $T: typeid) {
	src: T
	_reset(&src)
	defer _cleanup(&src)
	_copy_names(&d.names, src.names)
}

@(private = "file")
_reset :: proc {
	reset_Render_Layers,
	reset_Physics_Layers,
}

@(private = "file")
_cleanup :: proc {
	cleanup_Render_Layers,
	cleanup_Physics_Layers,
}

// Rewrites `dst` with the names of `src`, in place. A name that did not change
// keeps its string.
@(private = "file")
_copy_names :: proc(dst: ^[LAYER_COUNT]string, src: [LAYER_COUNT]string) {
	for &name, i in dst {
		if name == src[i] do continue
		delete(name)
		name = strings.clone(src[i])
	}
}
