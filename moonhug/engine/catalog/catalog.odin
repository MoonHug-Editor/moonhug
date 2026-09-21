package catalog

// The asset catalog FILE: one dictionary mapping every asset guid to its
// source path, artifact key, and baked import settings (Unity's Addressables
// catalog idea, reduced to what the app under the catalog pipeline needs).
//
// This is a leaf package on purpose: run configs stage build data with
// export_from, and a config binary must not pull the whole engine (SDL, GPU)
// just to copy files. The engine's live halves — writing the catalog from
// the AssetDB, running the catalog pipeline from it — live in engine/asset_catalog.odin.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

VERSION :: 1

Entry :: struct {
	path:     string,
	artifact: string, // content-address key; "" = source-read asset (no artifact)
	settings: string, // import settings baked as JSON text; "" = defaults / none
}

File :: struct {
	version: int,
	// Exported catalogs are relocatable: entry paths and the artifacts dir
	// resolve relative to the catalog file's own directory, so the data dir
	// moves as one unit. An in-place catalog (false) resolves against the cwd
	// and reads the working tree's assets/ and library/ directly.
	relocatable: bool,
	// The scene a catalog pipeline loads when no scene argument is given (guid
	// string). Stamped by export_from from the config's pinned scene.
	boot_scene: string,
	assets:     map[string]Entry, // guid string -> entry
}

// Everything parses into `allocator` (callers usually pass temp).
parse :: proc(data: []byte, allocator := context.temp_allocator) -> (cf: File, ok: bool) {
	if json.unmarshal(data, &cf, allocator = allocator) != nil do return {}, false
	return cf, true
}

save :: proc(cf: ^File, path: string) -> bool {
	opts := json.Marshal_Options{
		spec = .JSON, pretty = true, use_spaces = true, spaces = 2,
		sort_maps_by_key = true,
	}
	data, merr := json.marshal(cf^, opts, context.temp_allocator)
	if merr != nil {
		fmt.eprintfln("[Catalog] marshal failed: %v", merr)
		return false
	}
	ensure_parent_dirs(path)
	if os.write_entire_file(path, data) != nil {
		fmt.eprintfln("[Catalog] failed to write %s", path)
		return false
	}
	return true
}

// The export step, driven entirely by an existing catalog file: copy the
// assets the boot scene needs, with their artifacts, into `data_dir` and
// write a RELOCATABLE catalog beside them, boot scene stamped.
//
// WHAT SHIPS is the dependency closure of the roots (see _closure): the boot
// scene, plus every asset under a folder named `resources`, plus everything
// they reference, transitively. An asset the game loads by path at runtime
// is invisible to the walk, so it lives under a `resources` folder or it does
// not ship. With no boot scene there is no root to walk from, and the whole
// catalog ships.
//
// - `root` prefixes reads of entry sources: "" when entry paths are valid
//   from the cwd (the editor), "moonhug" when invoked from the repo root the
//   way run configs are.
// - artifacts read from the artifacts/ dir beside the source catalog. That
//   rule covers both layouts: library/catalog.json sits beside
//   library/artifacts, an exported catalog sits beside its artifacts/.
// - `boot_scene` is an entry path resolved to its guid; "" skips the stamp
//   and a path not in the catalog fails the export.
export_from :: proc(src_catalog: string, data_dir: string, boot_scene := "", root := "") -> bool {
	data, read_err := os.read_entire_file(src_catalog, context.temp_allocator)
	if read_err != nil {
		fmt.eprintfln("[Catalog] export: cannot read %s", src_catalog)
		return false
	}
	src, pok := parse(data)
	if !pok {
		fmt.eprintfln("[Catalog] export: cannot parse %s", src_catalog)
		return false
	}
	if src.relocatable {
		fmt.eprintfln("[Catalog] export: %s is already an export", src_catalog)
		return false
	}

	src_dir: string
	{
		context.allocator = context.temp_allocator
		src_dir = filepath.dir(src_catalog)
	}

	boot_guid: string
	if boot_scene != "" {
		for guid_str, entry in src.assets do if entry.path == boot_scene do boot_guid = guid_str
		if boot_guid == "" {
			fmt.eprintfln("[Catalog] export: boot scene %s is not in the catalog", boot_scene)
			return false
		}
	}

	ship, cok := _closure(&src, boot_guid, root)
	if !cok do return false

	// Stage into an EMPTY dir, so the export is exactly the closure and not
	// the closure on top of whatever the last export left behind. Only a dir
	// that is itself an export (holds a catalog.json) is cleared: anything
	// else at that path is someone's data, and the export refuses rather than
	// guess.
	if os.exists(data_dir) {
		if !os.exists(strings.concatenate({data_dir, "/catalog.json"}, context.temp_allocator)) {
			fmt.eprintfln("[Catalog] export: %s exists and is not an export (no catalog.json) — refusing to clear it", data_dir)
			return false
		}
		if !_remove_tree(data_dir) {
			fmt.eprintfln("[Catalog] export: cannot clear %s", data_dir)
			return false
		}
	}

	out := File{version = VERSION, relocatable = true, boot_scene = boot_guid}
	out.assets = make(map[string]Entry, len(ship), context.temp_allocator)

	copied := 0
	for guid_str in ship {
		entry := src.assets[guid_str]
		src_path := _rooted(root, entry.path)
		dst := strings.concatenate({data_dir, "/", entry.path}, context.temp_allocator)
		if os.is_dir(src_path) {
			// Folders are guid-addressable assets too (they carry metas) —
			// mirror the directory, nothing to copy.
			ensure_parent_dirs(strings.concatenate({dst, "/x"}, context.temp_allocator))
		} else {
			if !_copy_file(src_path, dst) {
				fmt.eprintfln("[Catalog] export: cannot copy %s", src_path)
				return false
			}
			copied += 1
		}

		// The whole-key artifact plus any mesh part files (<key>_m<i>.bin, the
		// naming asset_importer_mesh.odin owns). A missing artifact fails the
		// export instead of shipping a hole.
		if entry.artifact != "" {
			rel := strings.concatenate({"artifacts/", entry.artifact[:2], "/", entry.artifact, ".bin"}, context.temp_allocator)
			asrc := strings.concatenate({src_dir, "/", rel}, context.temp_allocator)
			adst := strings.concatenate({data_dir, "/", rel}, context.temp_allocator)
			if !_copy_file(asrc, adst) {
				fmt.eprintfln("[Catalog] export: missing artifact for %s — run an import pass first", entry.path)
				return false
			}
			copied += 1
			base_src := strings.trim_suffix(asrc, ".bin")
			base_dst := strings.trim_suffix(adst, ".bin")
			for i := 0; ; i += 1 {
				part_src := fmt.tprintf("%s_m%d.bin", base_src, i)
				if !os.exists(part_src) do break
				if !_copy_file(part_src, fmt.tprintf("%s_m%d.bin", base_dst, i)) do return false
				copied += 1
			}
		}

		out.assets[guid_str] = entry
	}

	catalog_path := strings.concatenate({data_dir, "/catalog.json"}, context.temp_allocator)
	if !save(&out, catalog_path) do return false
	fmt.printfln("[Catalog] exported %s (%d of %d assets, %d files)", data_dir, len(out.assets), len(src.assets), copied)
	return true
}

// The folder name whose contents always ship, for assets the game loads by
// path at runtime. Any depth: "assets/resources/x.png" and
// "assets/ui/resources/x.png" both qualify.
RESOURCES_DIR :: "resources"

// The set of guids to ship: the roots and everything reachable from them.
//
// An edge is found by HARVESTING guids from the asset's bytes: every serialized
// reference in this engine is the same hyphenated 36-character guid string, in
// scenes, prefabs, materials, animations and baked import settings alike, so
// one scan covers every asset type and a type that adds a reference field is
// covered without anyone touching this. The scan is deliberately dumb: it can
// only ship too much, never too little. A binary source (png, glb) matches
// nothing and is a leaf.
//
// A harvested string that is not a catalog key is skipped, not reported:
// scenes also carry component TYPE guids, which are not assets.
//
// Folders are catalog entries too, so each shipped asset's ancestor folders
// ship with it and the exported tree keeps the same shape.
//
// `boot_guid == ""` means no root, and the whole catalog ships.
@(private = "file")
_closure :: proc(src: ^File, boot_guid: string, root: string) -> (ship: [dynamic]string, ok: bool) {
	ship = make([dynamic]string, context.temp_allocator)
	if boot_guid == "" {
		for guid_str in src.assets do append(&ship, guid_str)
		return ship, true
	}

	seen := make(map[string]bool, len(src.assets), context.temp_allocator)
	push :: proc(ship: ^[dynamic]string, seen: ^map[string]bool, guid_str: string) {
		if guid_str in seen do return
		seen[guid_str] = true
		append(ship, guid_str)
	}

	push(&ship, &seen, boot_guid)
	for guid_str, entry in src.assets {
		if _under_resources(entry.path) do push(&ship, &seen, guid_str)
	}

	// Breadth-first over `ship` itself: it grows while it is walked.
	for i := 0; i < len(ship); i += 1 {
		entry := src.assets[ship[i]]
		src_path := _rooted(root, entry.path)
		if !os.is_dir(src_path) {
			data, read_err := os.read_entire_file(src_path, context.temp_allocator)
			if read_err != nil {
				fmt.eprintfln("[Catalog] export: cannot read %s", src_path)
				return ship, false
			}
			_harvest_guids(string(data), src, &ship, &seen)
		}
		_harvest_guids(entry.settings, src, &ship, &seen)
	}

	// Ancestor folders of everything shipped.
	path_to_guid := make(map[string]string, len(src.assets), context.temp_allocator)
	for guid_str, entry in src.assets do path_to_guid[entry.path] = guid_str
	for i := 0; i < len(ship); i += 1 {
		dir := src.assets[ship[i]].path
		for {
			slash := strings.last_index_byte(dir, '/')
			if slash < 0 do break
			dir = dir[:slash]
			if g, has := path_to_guid[dir]; has do push(&ship, &seen, g)
		}
	}
	return ship, true
}

@(private = "file")
_under_resources :: proc(path: string) -> bool {
	for seg in strings.split(path, "/", context.temp_allocator) {
		if seg == RESOURCES_DIR do return true
	}
	return false
}

GUID_LEN :: 36

// Appends every catalog guid that appears in `text` as a 8-4-4-4-12 hex
// string. Guids are written lowercase everywhere (core:encoding/uuid), so the
// match is exact.
@(private = "file")
_harvest_guids :: proc(text: string, src: ^File, ship: ^[dynamic]string, seen: ^map[string]bool) {
	if len(text) < GUID_LEN do return
	for i := 0; i + GUID_LEN <= len(text); i += 1 {
		if !_is_guid(text[i:i + GUID_LEN]) do continue
		if _, has := src.assets[text[i:i + GUID_LEN]]; has {
			if text[i:i + GUID_LEN] not_in seen {
				seen[text[i:i + GUID_LEN]] = true
				append(ship, text[i:i + GUID_LEN])
			}
		}
		i += GUID_LEN - 1
	}
}

@(private = "file")
_is_guid :: proc(s: string) -> bool {
	for c, i in transmute([]byte)s {
		switch i {
		case 8, 13, 18, 23:
			if c != '-' do return false
		case:
			if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') do return false
		}
	}
	return true
}

// Create every missing parent segment of a FILE path — os.make_directory is
// non-recursive.
ensure_parent_dirs :: proc(path: string) {
	dir: string
	{
		context.allocator = context.temp_allocator
		dir = filepath.dir(path)
	}
	for i := 0; i <= len(dir); i += 1 {
		if i == len(dir) || dir[i] == '/' {
			if i > 0 do os.make_directory(dir[:i])
		}
	}
}

@(private = "file")
_rooted :: proc(root, path: string) -> string {
	if root == "" do return path
	return strings.concatenate({root, "/", path}, context.temp_allocator)
}

// os.remove takes an empty dir, so the tree is walked bottom-up.
@(private = "file")
_remove_tree :: proc(path: string) -> bool {
	if !os.is_dir(path) do return os.remove(path) == nil
	handle, oerr := os.open(path)
	if oerr != nil do return false
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	os.close(handle)
	if rerr != nil do return false
	for e in entries {
		if !_remove_tree(strings.concatenate({path, "/", e.name}, context.temp_allocator)) do return false
	}
	return os.remove(path) == nil
}

@(private = "file")
_copy_file :: proc(src, dst: string) -> bool {
	data, read_err := os.read_entire_file(src, context.temp_allocator)
	if read_err != nil do return false
	ensure_parent_dirs(dst)
	return os.write_entire_file(dst, data) == nil
}
