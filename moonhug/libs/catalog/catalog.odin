package catalog

// The asset catalog FILE: one dictionary mapping every asset guid to its
// source path, artifact key, and baked import settings (Unity's Addressables
// catalog idea, reduced to what the app under the catalog pipeline needs).
//
// This is a leaf package on purpose: run configs build the catalog from the
// project's files (build) and stage build data from it (export), and a
// config binary must not pull the whole engine (SDL, GPU) just to copy files.
// Nothing needs the type registry: the .meta files hold the settings as the
// JSON the game parses, and library/artifact_db.json holds the artifact keys,
// so the catalog is a projection of what the editor's last import left on
// disk and is never stale on its own. The engine's half, running the catalog
// pipeline from a file, lives in libs/assets/asset_catalog.odin.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

VERSION :: 2

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
// assets the boot scene needs into `data_dir` and write a RELOCATABLE
// catalog beside them, boot scene stamped.
//
// ONE REPRESENTATION PER ASSET. An asset with an artifact ships the artifact
// and not its source: every runtime loader reads the artifact and falls back
// to the source only by requesting an import, which the catalog pipeline
// refuses. An asset without an artifact (scene, material, prefab) ships its
// source. The entry keeps its path either way, since the path is the key
// settings and type lookups use. No importer declares which it is, the
// artifact's existence is the declaration.
//
// WHAT SHIPS is the dependency closure of the roots (see _closure): the boot
// scene, every asset under a folder named `resources`, the assets the files
// in `extra_roots` reference, plus everything they reference, transitively. An asset the game loads by path at runtime
// is invisible to the walk, so it lives under a `resources` folder or it does
// not ship. With no boot scene there is no root to walk from, and the whole
// catalog ships.
//
// SUB-ASSET FILES ship only when something references them. An importer
// writes each sub-asset that has data of its own to <key>_s<local id>.bin
// (assets.artifact_sub_path): a model's parts, clips and convex
// decompositions. The file ships when a reference names its id, the main
// artifact ships when a reference names the asset itself (no local id) or an
// id with no file of its own (a sprite slice reads its texture), and an
// asset used whole (_Uses) ships everything. So a scene that plays one clip
// of an animation library ships that clip, not the library. Fan-out files
// without the `_s` marker hold shared data and always ship.
//
// - `root` prefixes reads of entry sources: "" when entry paths are valid
//   from the cwd (the editor), "moonhug" when invoked from the repo root the
//   way run configs are.
// - artifacts read from the artifacts/ dir beside the source catalog. That
//   rule covers both layouts: library/catalog.json sits beside
//   library/artifacts, an exported catalog sits beside its artifacts/.
// - `boot_scene` is an entry path resolved to its guid; "" skips the stamp
//   and a path not in the catalog fails the export.
// - `extra_roots` are files that are not catalog entries but run against the
//   export, such as the editor's live-scene snapshot: their references ship,
//   the boot scene stamp stays. Read through `root` like entry sources. A
//   file that cannot be read fails the export.
export_from :: proc(src_catalog: string, data_dir: string, boot_scene := "", root := "", extra_roots: []string = nil) -> bool {
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
	return export(&src, src_dir, data_dir, boot_scene, root, extra_roots)
}

// The same from a catalog in memory (build), with `src_dir` the library
// folder its artifact keys resolve in (its artifacts/ fan-out).
export :: proc(src: ^File, src_dir: string, data_dir: string, boot_scene := "", root := "", extra_roots: []string = nil) -> bool {
	boot_guid: string
	if boot_scene != "" {
		for guid_str, entry in src.assets do if entry.path == boot_scene do boot_guid = guid_str
		if boot_guid == "" {
			fmt.eprintfln("[Catalog] export: boot scene %s is not in the catalog", boot_scene)
			return false
		}
	}

	uses: _Uses
	ship, cok := _closure(src, boot_guid, root, extra_roots, &uses)
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

	copied, skipped := 0, 0
	for guid_str in ship {
		entry := src.assets[guid_str]
		src_path := _rooted(root, entry.path)
		dst := strings.concatenate({data_dir, "/", entry.path}, context.temp_allocator)
		if os.is_dir(src_path) {
			// Folders are guid-addressable assets too (they carry metas) —
			// mirror the directory, nothing to copy.
			ensure_parent_dirs(strings.concatenate({dst, "/x"}, context.temp_allocator))
		} else if entry.artifact == "" {
			if !_copy_file(src_path, dst) {
				fmt.eprintfln("[Catalog] export: cannot copy %s", src_path)
				return false
			}
			copied += 1
		}

		// The main artifact plus the fan-out files beside it
		// (<key>_<suffix>.bin), each when something needs it. A missing main
		// artifact fails the export instead of shipping a hole.
		if entry.artifact != "" {
			dir_rel := strings.concatenate({"artifacts/", entry.artifact[:2], "/"}, context.temp_allocator)
			main_name := strings.concatenate({entry.artifact, ".bin"}, context.temp_allocator)
			if !os.exists(strings.concatenate({src_dir, "/", dir_rel, main_name}, context.temp_allocator)) {
				fmt.eprintfln("[Catalog] export: missing artifact for %s — run an import pass first", entry.path)
				return false
			}
			files := make([dynamic]string, context.temp_allocator)
			append(&files, main_name)
			prefix := strings.concatenate({entry.artifact, "_"}, context.temp_allocator)
			if handle, oerr := os.open(strings.concatenate({src_dir, "/", dir_rel}, context.temp_allocator)); oerr == nil {
				defer os.close(handle)
				infos, _ := os.read_dir(handle, -1, context.temp_allocator)
				for f in infos {
					if strings.has_prefix(f.name, prefix) && strings.has_suffix(f.name, ".bin") do append(&files, f.name)
				}
			}
			for name in files {
				if !_artifact_file_needed(guid_str, name[len(entry.artifact):len(name) - len(".bin")], entry.artifact, files[:], &uses) {
					skipped += 1
					continue
				}
				rel := strings.concatenate({dir_rel, name}, context.temp_allocator)
				if !_copy_file(strings.concatenate({src_dir, "/", rel}, context.temp_allocator), strings.concatenate({data_dir, "/", rel}, context.temp_allocator)) {
					fmt.eprintfln("[Catalog] export: cannot copy %s", rel)
					return false
				}
				copied += 1
			}
		}

		out.assets[guid_str] = entry
	}

	catalog_path := strings.concatenate({data_dir, "/catalog.json"}, context.temp_allocator)
	if !save(&out, catalog_path) do return false
	fmt.printfln("[Catalog] exported %s (%d of %d assets, %d files, %d unused artifact files left out)", data_dir, len(out.assets), len(src.assets), copied, skipped)
	return true
}

// --- The catalog from the project's files -------------------------------------

// Every asset with a .meta under `asset_dirs`: its guid, its import settings
// as the meta holds them, and its artifact key from `library_dir`/artifact_db.json. `root` ("moonhug" from
// the repository root, "" from inside it) prefixes the dirs and the library
// and is no part of the entry paths, which are the asset database's own
// ("assets/x.png", "packages/app/assets/x.png"). A run config builds the
// catalog this way when it needs it. Parsed into `allocator`.
build :: proc(root: string, asset_dirs: []string, library_dir: string, allocator := context.temp_allocator) -> (cf: File, ok: bool) {
	cf = File{version = VERSION}
	cf.assets = make(map[string]Entry, allocator)
	index := _artifact_index_read(_rooted(root, strings.concatenate({library_dir, "/artifact_db.json"}, context.temp_allocator)))
	for dir in asset_dirs {
		if !_build_dir(&cf, root, dir, &index, allocator) do return cf, false
	}
	return cf, true
}

// build, saved to `path`.
build_to_file :: proc(root: string, asset_dirs: []string, library_dir: string, path: string) -> bool {
	cf, ok := build(root, asset_dirs, library_dir)
	if !ok do return false
	return save(&cf, path)
}

// The asset roots of a project under `root`: "assets" and every installed
// package's "packages/<name>/assets" (a symlinked package included), the
// folders the editor's asset database scans. Temp-allocated.
project_asset_dirs :: proc(root: string) -> []string {
	dirs := make([dynamic]string, context.temp_allocator)
	append(&dirs, "assets")
	packages := _rooted(root, "packages")
	handle, err := os.open(packages)
	if err != nil do return dirs[:]
	defer os.close(handle)
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil do return dirs[:]
	names := make([dynamic]string, context.temp_allocator)
	for e in entries {
		if strings.has_prefix(e.name, ".") do continue
		if !os.is_dir(strings.concatenate({packages, "/", e.name, "/assets"}, context.temp_allocator)) do continue
		append(&names, e.name)
	}
	slice.sort(names[:])
	for n in names do append(&dirs, strings.concatenate({"packages/", n, "/assets"}, context.temp_allocator))
	return dirs[:]
}

// guid -> artifact key of library/artifact_db.json. Empty when there is no
// index yet: every asset then counts as source-read, and an export that
// needs an artifact says so.
@(private = "file")
_artifact_index_read :: proc(path: string) -> map[string]string {
	index := make(map[string]string, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return index
	root, perr := json.parse(data, .JSON, true, context.temp_allocator)
	if perr != nil do return index
	obj, is_obj := root.(json.Object)
	if !is_obj do return index
	for guid, v in obj {
		entry, eok := v.(json.Object)
		if !eok do continue
		if key, kok := entry["artifact"].(json.String); kok do index[guid] = string(key)
	}
	return index
}

// One folder's entries, folders included, then its subfolders. A file or
// folder without a .meta is not an asset.
@(private = "file")
_build_dir :: proc(cf: ^File, root: string, dir: string, index: ^map[string]string, allocator: runtime.Allocator) -> bool {
	abs_dir := _rooted(root, dir)
	handle, err := os.open(abs_dir)
	if err != nil {
		fmt.eprintfln("[Catalog] build: cannot read %s", abs_dir)
		return false
	}
	defer os.close(handle)
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil {
		fmt.eprintfln("[Catalog] build: cannot read %s", abs_dir)
		return false
	}
	for e in entries {
		if strings.has_prefix(e.name, ".") || strings.has_suffix(e.name, ".meta") do continue
		path := strings.concatenate({dir, "/", e.name}, context.temp_allocator)
		abs := _rooted(root, path)
		if meta, merr := os.read_entire_file(strings.concatenate({abs, ".meta"}, context.temp_allocator), context.temp_allocator); merr == nil {
			if !_build_entry(cf, path, meta, index, allocator) do return false
		}
		if os.is_dir(abs) {
			if !_build_dir(cf, root, path, index, allocator) do return false
		}
	}
	return true
}

// The entry of one .meta: its guid and its settings object as compact JSON.
@(private = "file")
_build_entry :: proc(cf: ^File, path: string, meta: []byte, index: ^map[string]string, allocator: runtime.Allocator) -> bool {
	root, perr := json.parse(meta, .JSON, true, context.temp_allocator)
	if perr != nil {
		fmt.eprintfln("[Catalog] build: cannot parse %s.meta", path)
		return false
	}
	obj, is_obj := root.(json.Object)
	guid, gok := obj["guid"].(json.String)
	if !is_obj || !gok || len(guid) == 0 {
		fmt.eprintfln("[Catalog] build: %s.meta names no guid", path)
		return false
	}
	entry := Entry{path = strings.clone(path, allocator)}
	if key, has := index[string(guid)]; has do entry.artifact = strings.clone(key, allocator)
	if settings, sok := obj["settings"].(json.Object); sok {
		text, merr := json.marshal(json.Value(settings), {spec = .JSON, sort_maps_by_key = true}, allocator)
		if merr != nil {
			fmt.eprintfln("[Catalog] build: cannot marshal the settings of %s", path)
			return false
		}
		entry.settings = string(text)
	}
	cf.assets[strings.clone(string(guid), allocator)] = entry
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
_closure :: proc(src: ^File, boot_guid: string, root: string, extra_roots: []string, uses: ^_Uses) -> (ship: [dynamic]string, ok: bool) {
	ship = make([dynamic]string, context.temp_allocator)
	uses.whole = make(map[string]bool, len(src.assets), context.temp_allocator)
	uses.itself = make(map[string]bool, len(src.assets), context.temp_allocator)
	uses.ids = make(map[string][dynamic]i64, context.temp_allocator)
	if boot_guid == "" {
		for guid_str in src.assets {
			append(&ship, guid_str)
			uses.whole[guid_str] = true
		}
		return ship, true
	}

	seen := make(map[string]bool, len(src.assets), context.temp_allocator)
	push :: proc(ship: ^[dynamic]string, seen: ^map[string]bool, guid_str: string) {
		if guid_str in seen do return
		seen[guid_str] = true
		append(ship, guid_str)
	}

	path_to_guid := make(map[string]string, len(src.assets), context.temp_allocator)
	for guid_str, entry in src.assets do path_to_guid[entry.path] = guid_str

	// A root is used whole: nothing names which of its parts it needs.
	push(&ship, &seen, boot_guid)
	uses.whole[boot_guid] = true
	for guid_str, entry in src.assets {
		if !_under_resources(entry.path) do continue
		push(&ship, &seen, guid_str)
		uses.whole[guid_str] = true
	}
	for extra in extra_roots {
		path := _rooted(root, extra)
		data, read_err := os.read_entire_file(path, context.temp_allocator)
		if read_err != nil {
			fmt.eprintfln("[Catalog] export: cannot read %s", path)
			return ship, false
		}
		_harvest_guids(string(data), src, &ship, &seen, uses)
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
			_harvest_guids(string(data), src, &ship, &seen, uses)
		}
		_harvest_guids(entry.settings, src, &ship, &seen, uses)
	}

	// Ancestor folders of everything shipped.
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
// match is exact. Each occurrence is also recorded in `uses`.
@(private = "file")
_harvest_guids :: proc(text: string, src: ^File, ship: ^[dynamic]string, seen: ^map[string]bool, uses: ^_Uses) {
	if len(text) < GUID_LEN do return
	for i := 0; i + GUID_LEN <= len(text); i += 1 {
		g := text[i:i + GUID_LEN]
		if !_is_guid(g) do continue
		if _, has := src.assets[g]; has {
			if g not_in seen {
				seen[g] = true
				append(ship, g)
			}
			if id := _local_id_beside(text, i, i + GUID_LEN); id != 0 {
				if g not_in uses.ids do uses.ids[g] = make([dynamic]i64, context.temp_allocator)
				append(&uses.ids[g], id)
			} else {
				uses.itself[g] = true
			}
		}
		i += GUID_LEN - 1
	}
}

// How the export walk saw each shipped asset referenced.
@(private = "file")
_Uses :: struct {
	// A root, an asset under a resources folder, or every asset of an export
	// with no boot scene: code may load any part of it, so all of it ships.
	whole:  map[string]bool,
	// Named with no local id (bare, or id 0): the asset itself, whose data is
	// its main artifact.
	itself: map[string]bool,
	// The local ids references name. A PPtr is written
	// {"guid": "<g>", "local_id": <id>}, its keys in either order.
	ids:    map[string][dynamic]i64,
}

// Whether one artifact file of a shipped asset ships. `suffix` is the name
// between the key and ".bin": "" for the main artifact, "_s<id>" for a
// sub-asset file, anything else for shared data. `files` lists the asset's
// artifact files, so an id with no file of its own sends the main artifact.
@(private = "file")
_artifact_file_needed :: proc(guid_str, suffix, key: string, files: []string, uses: ^_Uses) -> bool {
	if uses.whole[guid_str] do return true
	// Copied out: ranging over `uses.ids[guid_str]` itself takes the map
	// value's address, which is nil for an asset no id names, and crashes.
	ids := uses.ids[guid_str]
	if suffix == "" {
		if uses.itself[guid_str] do return true
		for id in ids {
			own := fmt.tprintf("%s_s%d.bin", key, id)
			has := false
			for f in files do if f == own do has = true
			if !has do return true
		}
		return false
	}
	id, is_sub := _sub_id(suffix)
	if !is_sub do return true
	for want in ids do if want == id do return true
	return false
}

// The local id in a sub-asset file's suffix ("_s<id>").
@(private = "file")
_sub_id :: proc(suffix: string) -> (i64, bool) {
	if !strings.has_prefix(suffix, "_s") do return 0, false
	return strconv.parse_i64(suffix[2:])
}

// The local id of a PPtr whose guid string spans text[start:end]: the value
// of a "guid" key, with "local_id" written after it or before it. 0 when the
// guid is no PPtr's or the PPtr has no local id.
@(private = "file")
_local_id_beside :: proc(text: string, start, end: int) -> i64 {
	ws :: proc(c: u8) -> bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' }
	fwd :: proc(text: string, i: int) -> int {
		i := i
		for i < len(text) && ws(text[i]) do i += 1
		return i
	}
	back :: proc(text: string, i: int) -> int {
		i := i
		for i >= 0 && ws(text[i]) do i -= 1
		return i
	}
	// `s` ends at text[i].
	ends_at :: proc(text: string, i: int, s: string) -> bool {
		return i + 1 >= len(s) && i < len(text) && text[i + 1 - len(s):i + 1] == s
	}
	KEY :: `"local_id"`
	GUID_KEY :: `"guid"`

	// The guid is the value of a "guid" key.
	i := start - 1
	if i < 0 || text[i] != '"' do return 0
	i = back(text, i - 1)
	if i < 0 || text[i] != ':' do return 0
	i = back(text, i - 1)
	if !ends_at(text, i, GUID_KEY) do return 0
	key_start := i + 1 - len(GUID_KEY)

	// After it: , "local_id" : <id>
	j := end
	if j < len(text) && text[j] == '"' {
		j = fwd(text, j + 1)
		if j < len(text) && text[j] == ',' {
			j = fwd(text, j + 1)
			if strings.has_prefix(text[j:], KEY) {
				j = fwd(text, j + len(KEY))
				if j < len(text) && text[j] == ':' {
					j = fwd(text, j + 1)
					k := j
					if k < len(text) && text[k] == '-' do k += 1
					for k < len(text) && text[k] >= '0' && text[k] <= '9' do k += 1
					id, ok := strconv.parse_i64(text[j:k])
					return id if ok else 0
				}
			}
		}
	}

	// Before it: "local_id" : <id> ,
	k := back(text, key_start - 1)
	if k < 0 || text[k] != ',' do return 0
	k = back(text, k - 1)
	digits_end := k + 1
	for k >= 0 && text[k] >= '0' && text[k] <= '9' do k -= 1
	if k >= 0 && text[k] == '-' do k -= 1
	digits_start := k + 1
	k = back(text, k)
	if k < 0 || text[k] != ':' do return 0
	k = back(text, k - 1)
	if !ends_at(text, k, KEY) do return 0
	id, ok := strconv.parse_i64(text[digits_start:digits_end])
	return id if ok else 0
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
