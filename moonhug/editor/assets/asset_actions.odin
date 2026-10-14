package asset_pipeline

import "base:runtime"
import "core:path/filepath"
import "core:strings"

// Asset actions: what the project view does to an asset beyond the database,
// such as opening its document. The shell declares the procs, a plugin
// installs them at EditorInit (the engine opens scenes). Every wrapper is
// nil-safe and reports false when nothing is installed.

Asset_Actions :: struct {
	// Opens the asset's document. A scene loads and becomes the active
	// scene. false when nothing handles the extension or the load failed.
	open:           proc(path: string) -> bool,
	// Opens the asset beside the documents already open (a scene loads
	// additively). false when nothing handles the extension.
	open_additive:  proc(path: string) -> bool,
	// Writes a variant of the asset at `base_path` to `variant_path`.
	create_variant: proc(base_path, variant_path: string) -> bool,
}

asset_actions: Asset_Actions

set_asset_actions :: proc(a: Asset_Actions) {
	asset_actions = a
}

// Opens the asset's document: the editor a package registered for the
// extension (asset_open_handler_add), else the installed open action.
asset_open :: proc(path: string) -> bool {
	if handler, ok := _open_handlers[strings.to_lower(filepath.ext(path), context.temp_allocator)]; ok {
		return handler(path)
	}
	if asset_actions.open == nil do return false
	return asset_actions.open(path)
}

// Registers the editor that opens assets with extension `ext` (".shadergraph"):
// what a double click or Enter on the asset in the Project view runs. One
// handler per extension, a later registration replaces an earlier one.
asset_open_handler_add :: proc(ext: string, handler: proc(path: string) -> bool) {
	context.allocator = runtime.default_allocator()
	if _open_handlers == nil do _open_handlers = make(map[string]proc(path: string) -> bool)
	_open_handlers[strings.clone(ext)] = handler
}

@(private = "file")
_open_handlers: map[string]proc(path: string) -> bool

asset_open_additive :: proc(path: string) -> bool {
	if asset_actions.open_additive == nil do return false
	return asset_actions.open_additive(path)
}

asset_create_variant :: proc(base_path, variant_path: string) -> bool {
	if asset_actions.create_variant == nil do return false
	return asset_actions.create_variant(base_path, variant_path)
}
