package physics3d

// Collision layers of the 3D colliders (assets/README.md "Collision layers").
// One asset type of this plugin, Physics3D_Layers, names the 32 layers and
// says which pairs of them collide. The Physics 3D project settings pick the
// asset the project uses. Unset is the built-in default: layer 0 "Default",
// and every pair colliding. Colliders and rigidbodies change their own share
// with Physics3D_Layer_Overrides.
//
// The plugin keeps a copy of the active asset, its names registered as the
// layer domain LAYER_DOMAIN. A switch to another asset, a change of its file
// on disk and an edit in the inspector all update the copy, whenever
// something reads the names (the layer picker) and at every physics step.

import "base:runtime"
import "core:strings"
import "moonhug:packages/engine"
import "moonhug:libs/log"

// The layer domain of the 3D colliders: their `layers` and the colliders'
// and rigidbodies' Physics3D_Layer_Overrides.
LAYER_DOMAIN :: "physics3d"

// The 32 collision layers of the 3D colliders. `names`: an empty name is an
// unused layer. `rows`: bit j of rows[i] set means a collider on layer i and
// a collider on layer j collide, kept symmetric by the inspector. A new asset
// names layer 0 "Default" and lets every pair collide.
@(typ_guid={guid = "567b1f11-329b-49c3-8675-212f97ec5f8a", menu_assets_create = {menu_name = "Physics 3D Layers", file_name = "Physics3DLayers.asset", order = -3}})
Physics3D_Layers :: struct {
	names: [engine.LAYER_COUNT]string,
	rows:  [engine.LAYER_COUNT]u32 `decor:collision_matrix(names="names")`,
}

// Layers a collider or a rigidbody collides with besides what the layer
// matrix says (include), and layers it never collides with, whatever the
// matrix says (exclude). A collider's own lists add to its rigidbody's
// (collision_mask).
Physics3D_Layer_Overrides :: struct {
	include: u32 `decor:layers(domain="physics3d") decor:tooltip(desc="Layers to collide with even where the layer matrix says not to.")`,
	exclude: u32 `decor:layers(domain="physics3d") decor:tooltip(desc="Layers never to collide with, whatever the layer matrix says.")`,
}

// A new Physics 3D Layers asset, and the layers without one: layer 0
// "Default", every pair colliding.
reset_Physics3D_Layers :: proc(l: ^Physics3D_Layers) {
	cleanup_Physics3D_Layers(l)
	l.names[0] = strings.clone("Default")
	for &row in l.rows do row = ~u32(0)
}

cleanup_Physics3D_Layers :: proc(l: ^Physics3D_Layers) {
	for s in l.names do delete(s)
	l^ = {}
}

// The layers that colliders on `layers` collide with by the active matrix:
// the rows of those layers, OR'd.
matrix_collides_with :: proc(layers: u32) -> u32 {
	out: u32
	for row, i in _layers.rows {
		if layers & (u32(1) << u32(i)) != 0 do out |= row
	}
	return out
}

// A collider's filter mask: the active matrix's rows for the collider's
// layers, plus its own and its rigidbody's includes, minus both excludes. Two
// colliders collide when each one's layers meet the other's mask, so an
// exclude on either side wins over an include on the other.
collision_mask :: proc(layers: u32, own, body: Physics3D_Layer_Overrides) -> u32 {
	return (matrix_collides_with(layers) | own.include | body.include) &~ (own.exclude | body.exclude)
}

// The active asset's names and matrix, on the default allocator. The layer
// registry holds a pointer to `names`.
@(private = "file")
_layers: struct {
	names:  [engine.LAYER_COUNT]string,
	rows:   [engine.LAYER_COUNT]u32,
	guid:   engine.Asset_GUID,
	loaded: bool,
}

@(init)
_layers_register :: proc "contextless" () {
	context = runtime.default_context()
	l: Physics3D_Layers
	reset_Physics3D_Layers(&l)
	defer cleanup_Physics3D_Layers(&l)
	_take(l)
	engine.layer_domain_register(LAYER_DOMAIN, &_layers.names, refresh = layers_sync)
	engine.asset_db_add_evict_hook(_layers_path_changed)
}

// Brings the names and the matrix up to date with the asset the Physics 3D
// settings name. A cheap check when nothing changed.
layers_sync :: proc() {
	context.allocator = runtime.default_allocator()
	_settings_ensure_loaded()
	want := physics3d_settings.layers
	if _layers.loaded && _layers.guid == want do return
	_layers.loaded = true
	_layers.guid = want
	l: Physics3D_Layers
	ok: bool
	if want != {} do l, ok = engine.asset_load_as(want, Physics3D_Layers)
	if !ok {
		if want != {} do log.warningf("[Physics3D] the settings name no readable Physics3D_Layers asset, using the built-in layers")
		reset_Physics3D_Layers(&l)
	}
	defer cleanup_Physics3D_Layers(&l)
	_take(l)
}

// Editor hook: an open document's current values replace the active copy when
// it is the asset the settings name, so an edit in the inspector reaches the
// layer picker and the physics step before it is saved.
layers_preview :: proc(guid: engine.Asset_GUID, l: Physics3D_Layers) {
	context.allocator = runtime.default_allocator()
	layers_sync()
	if guid != _layers.guid do return
	_take(l)
}

// An asset file changed on disk or went away: the copy reloads on the next
// sync when it is the active asset.
@(private = "file")
_layers_path_changed :: proc(path: string) {
	if !strings.has_suffix(path, ".asset") do return
	guid, ok := engine.asset_db_get_guid(path)
	if !ok do return
	if _layers.loaded && _layers.guid == engine.Asset_GUID(guid) do _layers.loaded = false
}

// Copies `l` into the active copy: the rows, and the names in place, so a name
// that did not change keeps its string.
@(private = "file")
_take :: proc(l: Physics3D_Layers) {
	_layers.rows = l.rows
	for &name, i in _layers.names {
		if name == l.names[i] do continue
		delete(name)
		name = strings.clone(l.names[i])
	}
}
