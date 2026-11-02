package assets

// One event for every change of an asset on disk, for the caches and editor
// state that hold something derived from it. A package declares a hook with
// @(asset_hook={ext="mat"}) on a proc named `asset_on_changed_<name>`, and
// the generated registration (asset_hook_gen) adds it here. The scan and the
// pipeline fire it, in the editor only: a game binary never changes its
// assets.
//
//   Modified    the scan found a created or modified source file, before the
//               pipeline imports it
//   Removed     the asset left the project, not renamed or moved, after the
//               scan, with the guid and path it had
//   Reimported  the pipeline rebuilt the asset's artifact, which is on disk
//
// A cache of a file reacts to Modified and Removed. A cache of an artifact
// reacts to Reimported, and may see Modified first, which it can ignore or
// act on twice. The hook gets the guid and the path, so it looks nothing up.
//
// Hooks on one change run by `order`, lower first, equal orders in
// registration order. A hook that unloads needs none. A hook that imports
// (the shader hot reload) declares a positive order, so every unload of the
// file has run before the import rebuilds its artifact.

import "base:runtime"
import "core:encoding/uuid"
import "core:path/filepath"
import "core:strings"
import core "moonhug:libs/core"

Asset_Change :: enum {
	Modified,
	Removed,
	Reimported,
}

Asset_Hook :: proc(guid: core.Asset_GUID, path: string, change: Asset_Change)

@(private = "file")
_Asset_Hook_Entry :: struct {
	ext:   string, // ".mat", "" for every asset
	hook:  Asset_Hook,
	order: int,
}

@(private = "file")
_asset_hooks: [dynamic]_Asset_Hook_Entry

// Registers `hook` for assets with extension `ext`, written with or without
// the dot, "" for every asset, at `order` among the hooks of one change.
// Registry state never borrows the caller's allocator: tests hand out scoped
// tracking allocators.
@(extension_point={attribute="asset_hook", target="proc", fields="ext order"})
asset_hook_add :: proc(ext: string, hook: Asset_Hook, order := 0) {
	context.allocator = runtime.default_allocator()
	e := ext
	if e != "" && e[0] != '.' do e = strings.concatenate({".", e})
	for h in _asset_hooks do if h.hook == hook && h.ext == e do return
	// Kept sorted: insert after the last entry of a lower or equal order.
	at := len(_asset_hooks)
	for h, i in _asset_hooks do if h.order > order { at = i; break }
	inject_at(&_asset_hooks, at, _Asset_Hook_Entry{ext = strings.clone(e), hook = hook, order = order})
}

// Tells every hook registered for the asset's extension that it changed.
asset_changed :: proc(guid: core.Asset_GUID, path: string, change: Asset_Change) {
	ext := filepath.ext(path)
	for h in _asset_hooks {
		if h.ext != "" && h.ext != ext do continue
		h.hook(guid, path, change)
	}
}

// Fired by the import for an asset whose artifact it rebuilt: an importer
// ran, or the index was re-pointed at another artifact.
_notify_reimported :: proc(guid: uuid.Identifier) {
	_artifact_failed_forget(core.Asset_GUID(guid))
	path := asset_db.guid_to_path[guid] or_else ""
	asset_changed(core.Asset_GUID(guid), path, .Reimported)
}
