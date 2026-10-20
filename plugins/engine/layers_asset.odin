package engine

// The render layer names asset (plugins/engine/docs/Layers.md): Render_Layers
// names the 32 render layers. A plain .asset file.
//
// The Layers project setting names the asset the project uses
// (Layers_Settings). An unset field is the essentials plugin's default asset,
// and the type's reset when that is not installed either.
//
// The engine keeps one copy of the active asset's names and registers it as
// the "render" layer domain, once. The registry's list never moves: a switch
// to another asset, a change of the file on disk and an edit in the inspector
// all rewrite the copy in place, so the layer picker always shows the current
// asset's names.

import "base:runtime"
import "core:encoding/uuid"
import "core:os"
import "core:strings"
import "moonhug:libs/log"

// The names of the 32 render layers. An empty name is an unused layer.
// Layers 0 ("Default") and 31 ("Editor") are built in: the inspector shows
// their names fixed, and the picker does not list layer 31.
@(typ_guid={guid = "61bc7a2f-3326-4f13-b233-7bccf12f709e", menu_assets_create = {menu_name = "Render Layers", file_name = "RenderLayers.asset", order = -3}})
Render_Layers :: struct {
	names: [LAYER_COUNT]string `decor:layer_names(builtin="0,31")`,
}

// The layer domain of the render layers: Transform.render_layer and the
// camera, light and probe masks.
LAYER_DOMAIN_RENDER :: "render"

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

// The Layers project setting: which Render Layers asset the project uses. A
// zero guid is the essentials plugin's default asset.
Layers_Settings :: struct {
	render_layers: Asset_GUID `ref:"Render_Layers" expand`,
}

@(project_settings={name="Layers"})
layers_settings: Layers_Settings

// Loads ProjectSettings/layers.json into layers_settings, once per engine run.
layers_settings_ensure_loaded :: proc() {
	if _layers_settings_loaded do return
	_layers_settings_loaded = true
	project_settings_load("Layers", &layers_settings)
}

// The asset a project uses when its Layers setting names none: the essentials
// plugin sets it to its default asset at EngineInit. Empty = the built-in
// names.
render_layers_default: Asset_GUID

// Reads a Render Layers file. A field the file lacks keeps its reset default.
// A file of another type does not load.
layers_load_file :: proc(path: string) -> (l: Render_Layers, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return {}, false
	return asset_parse_as(data, Render_Layers)
}

// The active asset's names, on the default allocator. The layer registry
// holds a pointer to `names`.
@(private = "file")
_render: struct {
	names:  [LAYER_COUNT]string,
	guid:   Asset_GUID,
	loaded: bool,
}

@(private = "file") _layers_settings_loaded: bool

@(init)
_layers_register :: proc "contextless" () {
	context = runtime.default_context()
	src: Render_Layers
	reset_Render_Layers(&src)
	defer cleanup_Render_Layers(&src)
	_copy_names(&_render.names, src.names)
	layer_domain_register(LAYER_DOMAIN_RENDER, &_render.names, hidden = 1 << RENDER_LAYER_EDITOR, refresh = layers_sync)
	asset_db_add_evict_hook(_layers_path_changed)
}

// The Render Layers asset the project uses now: the Layers setting's, else
// the installed default, else {} for the built-in names.
layers_active_guid :: proc() -> Asset_GUID {
	layers_settings_ensure_loaded()
	if layers_settings.render_layers != {} do return layers_settings.render_layers
	if render_layers_default == {} do return {}
	if _, installed := asset_db_get_path(uuid.Identifier(render_layers_default)); installed do return render_layers_default
	return {}
}

// Brings the registered names up to date with the asset the Layers setting
// names. A cheap check when nothing changed. The frame calls it
// (render_pipeline_active), and so does every read of the names
// (layer_domain_register's refresh).
layers_sync :: proc() {
	context.allocator = runtime.default_allocator()
	want := layers_active_guid()
	if _render.loaded && _render.guid == want do return
	_render.loaded = true
	_render.guid = want
	src: Render_Layers
	ok: bool
	if want != {} do src, ok = asset_load_as(want, Render_Layers)
	if !ok {
		if want != {} do log.warningf("[Layers] the Layers setting names no readable Render_Layers asset, using the built-in names")
		reset_Render_Layers(&src)
	}
	defer cleanup_Render_Layers(&src)
	_copy_names(&_render.names, src.names)
}

// Editor hook: a Render Layers document's current values replace the
// registered names when it is the asset the project uses, so an edit in the
// inspector reaches the layer picker before it is saved.
render_layers_preview :: proc(guid: Asset_GUID, l: Render_Layers) {
	context.allocator = runtime.default_allocator()
	layers_sync()
	if guid != _render.guid do return
	_copy_names(&_render.names, l.names)
}

// An asset file changed on disk or went away: the names reload on the next
// sync when it is the active asset.
@(private = "file")
_layers_path_changed :: proc(path: string) {
	if !strings.has_suffix(path, ".asset") do return
	guid, ok := asset_db_get_guid(path)
	if !ok do return
	if _render.loaded && _render.guid == Asset_GUID(guid) do _render.loaded = false
}

// The next sync reads the setting and the asset again. The registered names
// stay as they are.
_layers_shutdown :: proc() {
	_layers_settings_loaded = false
	_render.loaded = false
	_render.guid = {}
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
