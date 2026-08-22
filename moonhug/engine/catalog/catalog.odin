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

// The export step, driven entirely by an existing catalog file: copy every
// source and every referenced artifact into `data_dir` and write a
// RELOCATABLE catalog beside them, boot scene stamped.
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

	out := File{version = VERSION, relocatable = true}
	out.assets = make(map[string]Entry, len(src.assets), context.temp_allocator)

	copied := 0
	for guid_str, entry in src.assets {
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

		if boot_scene != "" && entry.path == boot_scene {
			out.boot_scene = guid_str
		}
		out.assets[guid_str] = entry
	}

	if boot_scene != "" && out.boot_scene == "" {
		fmt.eprintfln("[Catalog] export: boot scene %s is not in the catalog", boot_scene)
		return false
	}

	catalog_path := strings.concatenate({data_dir, "/catalog.json"}, context.temp_allocator)
	if !save(&out, catalog_path) do return false
	fmt.printfln("[Catalog] exported %s (%d assets, %d files)", data_dir, len(out.assets), copied)
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

@(private = "file")
_copy_file :: proc(src, dst: string) -> bool {
	data, read_err := os.read_entire_file(src, context.temp_allocator)
	if read_err != nil do return false
	ensure_parent_dirs(dst)
	return os.write_entire_file(dst, data) == nil
}
