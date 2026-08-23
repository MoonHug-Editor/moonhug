package subassets

// Sub-asset providers for the project window (Unity's expandable assets: a
// sliced texture unfolds to its sprites, a model to its meshes). A package's
// editor half registers a provider for its extensions at EditorInit; the
// project view asks the registry, so the editor root never imports the
// package. A sub-asset is addressed as PPtr{asset guid, local_id} — the id
// comes from the provider (persistent, minted by the asset's importer).

import "base:runtime"
import "moonhug:engine"

Sub_Asset :: struct {
	id:   engine.Local_ID,
	name: string, // borrowed from the provider's cache — use within the frame
	// Optional grid-cell preview: an imgui texture id plus this sub-asset's
	// uv rect within it, and its pixel size for aspect-fit. nil image = the
	// project view draws the type glyph.
	image:    rawptr,
	uv0, uv1: [2]f32,
	size:     [2]f32,
}

Provider :: struct {
	// Sub-assets of `path`, on `allocator` (names borrowed). Empty = the
	// asset has none right now (no fold arrow).
	list: proc(path: string, allocator: runtime.Allocator) -> []Sub_Asset,
	// Double-click on a sub-asset row (open the owning editor on it).
	open: proc(path: string, guid: engine.Asset_GUID, id: engine.Local_ID),
}

// Extension (lowercase, with dot: ".png") -> provider.
_providers: map[string]Provider

register :: proc(ext: string, p: Provider) {
	// Registry state never borrows the caller's allocator.
	context.allocator = runtime.default_allocator()
	if _providers == nil do _providers = make(map[string]Provider)
	_providers[ext] = p
}

find :: proc(ext: string) -> (Provider, bool) {
	p, ok := _providers[ext]
	return p, ok
}
