package subassets

// Sub-asset providers for the project window (Unity's expandable assets: a
// sliced texture unfolds to its sprites, a model to its meshes). A package's
// editor half registers a provider for its extensions at EditorInit; the
// Project window asks the registry, so the editor root never imports the
// package. A sub-asset is addressed as PPtr{asset guid, local_id} — the id
// comes from the provider (persistent, minted by the asset's importer). The
// clip sampler below is the same kind of seam for a model's clips.
//
// A sub-asset is derived or authored:
//   - derived: an importer made it from its file (a model's parts and clips,
//     a texture's sprites). It is listed and referenced, not edited
//   - authored: the file holds its data, and the inspector edits it as a
//     document, the way it edits a file of that type (a material kept in a
//     scene). Its provider gives `text`, `load` and `store`

import "base:runtime"
import "core:encoding/uuid"
import "core:fmt"
import "core:path/filepath"
import "core:strings"
import assets "moonhug:libs/assets"
import core "moonhug:libs/core"

Sub_Asset :: struct {
	id:   core.Local_ID,
	name: string, // borrowed from the provider's cache — use within the frame
	// What a reference field's `ext:` tag matches, spelled like a file
	// extension without the dot: "anim" for a model's clip. "" for a
	// sub-asset no field takes (a part, a convex decomposition).
	kind: string,
	// Optional grid-cell preview: an imgui texture id plus this sub-asset's
	// uv rect within it, and its pixel size for aspect-fit. nil image = the
	// Project window draws the type glyph.
	image:    rawptr,
	uv0, uv1: [2]f32,
	size:     [2]f32,
}

Provider :: struct {
	// Sub-assets of `path`, on `allocator` (names borrowed). Empty = the
	// asset has none right now (no fold arrow).
	list: proc(path: string, allocator: runtime.Allocator) -> []Sub_Asset,
	// Double-click on a sub-asset row (open the owning editor on it).
	open: proc(path: string, guid: core.Asset_GUID, id: core.Local_ID),
	// Authored sub-assets: the three procs of a file whose sub-assets are
	// documents. All nil for a file whose sub-assets are derived.
	//
	// The sub-asset's data as JSON text (temp), false when `ref` names none.
	// A document compares it with the text it last read or stored, and loads
	// again when the data changed under it.
	text:  proc(ref: core.PPtr) -> (text: string, ok: bool),
	// That text as a typed instance on context.allocator, its references to
	// the file's other sub-assets resolved.
	load:  proc(ref: core.PPtr, text: string) -> (data: any, ok: bool),
	// Writes the instance as the sub-asset's data into the file open in the
	// editor (`editable`), which then holds the unsaved edit and saves it
	// with the rest of the file. False when it cannot: the file is not open.
	store: proc(ref: core.PPtr, data: any) -> bool,
	// Writes the instance as the sub-asset's data into the file on disk, for
	// a file that is not open: the sub-asset's document holds the edit until
	// it is saved, like a file's. nil: a sub-asset of a file that is not
	// open is shown, not edited.
	save:  proc(ref: core.PPtr, data: any) -> bool,

	// Authored sub-assets the user manages: created, renamed and removed
	// in the editor. In a file open in the editor each is an undo step of
	// that file. In a file that is not open each goes into the file on disk,
	// a file operation with no undo. nil where the file does not take it.
	//
	// Whether the file is open in the editor now, a scene's while it is
	// loaded: a change of its sub-assets goes into the open file, is saved
	// with it and can be undone. nil: always.
	editable: proc(guid: core.Asset_GUID) -> bool,
	// Adds a sub-asset of `kind` named `name` to the file `owner`, with a
	// copy of the instance `data` as its data.
	create:   proc(owner: core.Asset_GUID, kind, name: string, data: any) -> (ref: core.PPtr, ok: bool),
	rename:   proc(ref: core.PPtr, name: string) -> bool,
	// A reference to a removed sub-asset stays and shows as missing.
	remove:   proc(ref: core.PPtr) -> bool,
}

// The extension a provider registers under for a file that has no path yet:
// a scene never saved. Its sub-assets are those of the empty guid, and its
// `list` is asked with an empty path.
NO_FILE :: ""

// The key the provider of embedded assets registers under: assets written
// inside the one field that uses them (core.EMBEDDED_ASSETS). It has `text`,
// `load` and `store`, so an embedded asset is edited as a document, and
// `create`, which makes one from an instance. Its `list` is for lookups
// only: nothing offers an embedded asset to another field.
EMBEDDED :: "<embedded>"

// Extension (lowercase, with dot: ".png") -> provider.
_providers: map[string]Provider

// One provider per extension. A second registration used to replace the
// first silently, so two packages each listing a model's sub-assets meant one
// list vanished with no trace of why. It is a wiring error, so it stops the
// editor where it happens.
register :: proc(ext: string, p: Provider) {
	// Registry state never borrows the caller's allocator.
	context.allocator = runtime.default_allocator()
	if _providers == nil do _providers = make(map[string]Provider)
	if ext in _providers {
		fmt.panicf("subassets: a provider for %q is already registered — extend it instead of registering a second one", ext)
	}
	_providers[ext] = p
}

// Takes the provider of `ext` out: for a test that registers its own.
unregister :: proc(ext: string) {
	delete_key(&_providers, ext)
}

find :: proc(ext: string) -> (Provider, bool) {
	p, ok := _providers[ext]
	return p, ok
}

// The provider of the file `guid` and the file's path: by its extension, or
// the NO_FILE provider with an empty path for the empty guid.
of :: proc(guid: core.Asset_GUID) -> (p: Provider, path: string, ok: bool) {
	if core.asset_guid_is_empty(guid) {
		p, ok = _providers[NO_FILE]
		return
	}
	if guid == core.EMBEDDED_ASSETS {
		p, ok = _providers[EMBEDDED]
		return
	}
	path = assets.asset_db_get_path(uuid.Identifier(guid)) or_return
	p, ok = _providers[strings.to_lower(filepath.ext(path), context.temp_allocator)]
	return
}

// The sub-asset `ref` names, as its file's provider lists it (name borrowed,
// temp). False for none.
get :: proc(ref: core.PPtr) -> (s: Sub_Asset, ok: bool) {
	if ref.local_id == 0 do return
	p, path := of(ref.guid) or_return
	if p.list == nil do return
	for e in p.list(path, context.temp_allocator) {
		if e.id == ref.local_id do return e, true
	}
	return
}

// Whether the sub-assets of the file `guid` can be changed now
// (Provider.editable).
editable :: proc(guid: core.Asset_GUID) -> bool {
	p, _, ok := of(guid)
	if !ok do return false
	return p.editable == nil || p.editable(guid)
}

// A name for a new sub-asset of the file `guid` that none of its sub-assets
// has: `base`, else `base` with the first free number after it ("Marble 1").
// A number `base` ends with is counted on from, not added to. Temp.
unique_name :: proc(guid: core.Asset_GUID, base: string) -> string {
	p, path, ok := of(guid)
	if !ok || p.list == nil do return base
	list := p.list(path, context.temp_allocator)
	taken :: proc(list: []Sub_Asset, name: string) -> bool {
		for s in list do if s.name == name do return true
		return false
	}
	if !taken(list, base) do return base
	stem := base
	if at := strings.last_index_byte(base, ' '); at > 0 && at + 1 < len(base) {
		digits := true
		for c in base[at + 1:] do if c < '0' || c > '9' do digits = false
		if digits do stem = base[:at]
	}
	for i := 1;; i += 1 {
		name := fmt.tprintf("%s %d", stem, i)
		if !taken(list, name) do return name
	}
}

// --- Asset types the user creates ----------------------------------------------

// An asset type with `menu_assets_create` on its @(typ_guid): Assets > Create
// makes a file of it, and a reference field that takes its kind makes a
// sub-asset of it in a file whose provider adds one (Provider.create).
Creatable :: struct {
	kind:     string, // the file's extension without the dot: "mat"
	title:    string, // "Material"
	type_key: core.TypeKey,
}

@(private)
_creatables: [dynamic]Creatable

// Called for each type by the generated register_create_asset_menus.
// `file_name` is the name Assets > Create gives a new file of the type.
creatable_register :: proc(file_name, title: string, type_key: core.TypeKey) {
	// Registry state never borrows the caller's allocator.
	context.allocator = runtime.default_allocator()
	kind := strings.trim_prefix(strings.to_lower(filepath.ext(file_name)), ".")
	append(&_creatables, Creatable{kind = kind, title = strings.clone(title), type_key = type_key})
}

creatables :: proc() -> []Creatable {
	return _creatables[:]
}

// What a kind is called: "Material" for "mat". The kind itself when no
// creatable type has it.
kind_title :: proc(kind: string) -> string {
	for c in _creatables do if c.kind == kind do return c.title
	return kind
}

// --- Model clips ------------------------------------------------------------------

// Poses the node hierarchy under `root` by the clip asset `clip` at `t`
// seconds and returns the clip's length. The Preview pane and the thumbnail
// of a clip inside a model pose the model's rig with it. The animation
// package installs it at EditorInit. nil: a model's clips have no preview and
// no thumbnail.
Clip_Sampler :: proc(root: core.Transform_Handle, clip: core.PPtr, t: f32) -> (length: f32, ok: bool)

clip_sampler: Clip_Sampler
