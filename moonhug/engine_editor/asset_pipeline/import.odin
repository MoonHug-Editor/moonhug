package asset_pipeline

// The asset pipeline's WRITE half: scanning, importing, meta writing, import
// settings editing. Editor-side by construction — this package never links
// into a game binary, so shipped builds carry no importer code and the app
// consumes what the editor produced (artifacts, catalog). The engine keeps
// the READ half: the artifact index, meta/settings reading, catalog init
// (engine/asset_pipeline.odin).
//
// Hooked into the engine at ImportersInit (editor mode): the AssetDB's
// import-meta hook (new files get importer metas during refresh) and a
// path-changed hook that reimports edited shaders (hot reload).

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:encoding/json"
import "core:encoding/uuid"
import xxh "core:hash/xxhash"
import "moonhug:engine"
import "moonhug:editor/progress"

// Bump to invalidate EVERY artifact (artifact container format changes).
// v2: settings hash covers the plain settings payload (typeid-driven blob,
// no union tag in the hashed bytes).
_ARTIFACT_FORMAT_VERSION :: 2

_importer_version :: proc(importer: string) -> int {
	if desc, ok := _importers[importer]; ok do return desc.version
	return 0
}

is_importable_extension :: proc(ext: string) -> bool {
	return ext in _importer_by_ext
}

// Fresh default-valued settings instance for an importer, allocated on
// `allocator`. Defaults come from the settings type's registered factory
// (typ_guid makeProcName) — no factory = zeroed.
_settings_new :: proc(importer: string, allocator := context.allocator) -> (settings: any, ok: bool) {
	desc, has := _importers[importer]
	if !has || desc.settings_tid == nil do return {}, false
	key, kok := engine.get_type_key_by_typeid(desc.settings_tid)
	if !kok do return {}, false
	context.allocator = allocator
	return engine.create_instance_by_type_key(key), true
}

// Engine seams, all nil in a game binary: writes that need a rescan
// (scene_save) request one, edited .glsl files reimport (shader hot reload —
// the direct shader_path_changed call in refresh evicts, this hook rebuilds),
// and loaders self-heal missing/stale artifacts by importing.
@(phase={key=ImportersInit, order=0, mode=Editor})
import_pipeline_install :: proc() {
	engine.asset_db_set_refresh_proc(asset_db_refresh)
	engine.asset_db_add_path_changed_hook(_reimport_changed_shader)
	engine.asset_pipeline_set_import_request(_import_requested)
}

@(private = "file")
_import_requested :: proc(source_path: string, force: bool) -> bool {
	return _import_asset(source_path, force)
}

@(private = "file")
_reimport_changed_shader :: proc(path: string) {
	if strings.has_suffix(path, ".glsl") {
		_ = asset_pipeline_import_asset(path)
	}
}

asset_pipeline_init :: proc() {
	os.make_directory(engine.LIBRARY_DIR)
	os.make_directory(engine.ARTIFACTS_DIR)
	engine._artifact_index_ensure()
}

asset_pipeline_import_all :: proc() {
	engine._artifact_index_batch_set(true) // one index write for the whole pass
	_import_directory(engine.asset_db.root_path)
	for root in engine.asset_db_package_roots() {
		_import_directory(root.assets_path)
	}
	engine._artifact_index_batch_set(false)
	engine._artifact_index_prune()
	engine._cleanup_stale_artifacts()
	engine._artifact_index_save()
	engine._asset_catalog_auto_write() // keep library/catalog.json current
	fmt.printf("[Pipeline] Import pass complete\n")
}

// Imports when needed: a source whose stamp AND settings match its index entry
// (with the artifact file present) is fresh and costs one stat + one meta
// read. Anything else computes the content key — a key whose artifact already
// exists (a setting toggled back) just re-points the index, no importer runs.
asset_pipeline_import_asset :: proc(source_path: string) -> bool {
	return _import_asset(source_path, force = false)
}

// Forced: always re-runs the importer into the current key's artifact.
asset_pipeline_reimport :: proc(source_path: string) -> bool {
	return _import_asset(source_path, force = true)
}

@(private = "file")
_import_asset :: proc(source_path: string, force: bool) -> bool {
	// Under the catalog pipeline content is fixed: a missing artifact is an
	// error to surface, never something to repair by importing.
	if engine.asset_db.pipeline == .Catalog {
		fmt.eprintf("[Pipeline] import of %s refused: the catalog pipeline has no importers\n", source_path)
		return false
	}
	ext := filepath.ext(source_path)
	if !is_importable_extension(ext) do return false

	meta_path := strings.concatenate({source_path, ".meta"}, context.temp_allocator)
	import_meta := engine._read_import_meta(meta_path)
	if import_meta.guid == "" do return false
	defer delete(import_meta.guid)

	guid, parse_err := uuid.read(import_meta.guid)
	if parse_err != nil do return false

	info, stat_err := os.stat(source_path, context.temp_allocator)
	if stat_err != nil do return false
	mtime := info.modification_time._nsec
	size := info.size

	settings_hex := _settings_hash_hex(import_meta.settings)
	if !force {
		if e, has := engine._artifact_index_lookup(guid); has &&
		   e.mtime == mtime && e.size == size && e.settings == settings_hex {
			if os.exists(engine._artifact_key_path(e.artifact, context.temp_allocator)) {
				return false
			}
		}
	}

	data, read_err := os.read_entire_file(source_path, context.temp_allocator)
	if read_err != nil do return false
	key := _artifact_key(data, import_meta.settings, importer_for_extension(ext))
	artifact_path := engine._artifact_key_path(key, context.temp_allocator)

	if force || !os.exists(artifact_path) {
		engine._ensure_artifact_dir(artifact_path)
		if !_run_import(source_path, artifact_path, import_meta.settings) do return false

		// An importer may REFINE its settings during the run (the mesh
		// importer maintains its part id table — Unity's
		// internalIDToNameTable). Persist the refinement and move the
		// artifacts under the refined content key, so the next refresh sees
		// a fresh entry instead of importing a second time.
		if refined_hex := _settings_hash_hex(import_meta.settings); refined_hex != settings_hex {
			_write_import_meta(meta_path, import_meta)
			refined_key := _artifact_key(data, import_meta.settings, importer_for_extension(ext))
			refined_path := engine._artifact_key_path(refined_key, context.temp_allocator)
			os.rename(artifact_path, refined_path)
			// Part fan-out files move with the main artifact (the catalog
			// export walks them the same way).
			for i := 0; ; i += 1 {
				old_part := engine.mesh_part_artifact_path(artifact_path, i, context.temp_allocator)
				if !os.exists(old_part) do break
				os.rename(old_part, engine.mesh_part_artifact_path(refined_path, i, context.temp_allocator))
			}
			key = refined_key
			settings_hex = refined_hex
		}
	}

	engine._artifact_index_set(guid, key, mtime, size, settings_hex)
	engine._artifact_index_save()
	engine._notify_reimported(guid)
	return true
}

_import_directory :: proc(dir_path: string) {
	handle, err := os.open(dir_path)
	if err != nil do return
	defer os.close(handle)

	entries, read_err := os.read_dir(handle, -1, context.temp_allocator)
	if read_err != nil do return
	defer os.file_info_slice_delete(entries, context.temp_allocator)

	for entry in entries {
		if strings.has_prefix(entry.name, ".") do continue

		full_path, _ := filepath.join({dir_path, entry.name}, context.temp_allocator)

		if entry.type == .Directory {
			_import_directory(full_path)
		} else {
			if strings.has_suffix(entry.name, ".meta") do continue
			progress.report(full_path)
			ext := filepath.ext(entry.name)
			if is_importable_extension(ext) {
				asset_pipeline_import_asset(full_path)
			}
		}
	}
}

asset_pipeline_save_settings :: proc(source_path: string, settings: any) -> bool {
	meta_path := strings.concatenate({source_path, ".meta"}, context.temp_allocator)

	import_meta := engine._read_import_meta(meta_path)
	if import_meta.guid == "" do return false
	defer delete(import_meta.guid)

	// The value must be the meta's own settings type — the importer string
	// in the meta decides the type, not the caller.
	desc, ok := _importers[import_meta.importer]
	if !ok || desc.settings_tid != settings.id do return false

	import_meta.settings = settings
	return _write_import_meta(meta_path, import_meta)
}

asset_pipeline_ensure_import_meta :: proc(asset_path: string) {
	ext := filepath.ext(asset_path)
	if !is_importable_extension(ext) do return

	meta_path := strings.concatenate({asset_path, ".meta"})
	defer delete(meta_path)

	existing := engine._read_import_meta(meta_path)
	if existing.guid != "" && existing.importer != "" {
		delete(existing.guid)
		return
	}

	guid_id: uuid.Identifier
	if existing.guid != "" {
		parsed, parse_err := uuid.read(existing.guid)
		if parse_err == nil {
			guid_id = parsed
		}
		delete(existing.guid)
	}

	if guid_id == {} {
		if g, ok := engine._read_meta(meta_path); ok {
			guid_id = g
		} else {
			guid_id = engine._generate_guid()
		}
	}

	guid_str := uuid.to_string(guid_id)
	defer delete(guid_str)

	importer_name := importer_for_extension(ext)
	settings, _ := _settings_new(importer_name, context.temp_allocator)

	new_meta := engine.ImportMeta{
		guid     = guid_str,
		importer = importer_name,
		settings = settings,
	}

	_write_import_meta(meta_path, new_meta)
}

@(private = "file")
_write_import_meta :: proc(meta_path: string, meta: engine.ImportMeta) -> bool {
	prev := context.allocator
	context.allocator = context.temp_allocator
	defer context.allocator = prev

	obj := make(json.Object)
	obj["guid"] = json.String(meta.guid)
	obj["importer"] = json.String(meta.importer)
	if meta.settings.data != nil {
		bytes, merr := json.marshal(meta.settings, {spec = .JSON})
		if merr != nil do return false
		v, perr := json.parse(bytes, .JSON, true)
		if perr != nil do return false
		if sobj, is_obj := v.(json.Object); is_obj {
			// The type tag settings materialization reads (engine
			// _read_import_meta resolves it via create_instance_by_guid).
			sobj["__type_guid"] = json.String(uuid.to_string(engine.get_guid_by_typeid(meta.settings.id)))
			obj["settings"] = sobj
		}
	}

	opts := json.Marshal_Options{
		spec       = .JSON,
		pretty     = true,
		use_spaces = true,
		spaces     = 2,
		sort_maps_by_key = true, // json.Object is a map — deterministic files
	}
	data, err := json.marshal(json.Value(obj), opts)
	if err != nil do return false

	return os.write_entire_file(meta_path, data) == nil
}

// --- Content keys -------------------------------------------------------------

@(private = "file")
_settings_hash_hex :: proc(settings: any) -> string {
	if settings.data == nil do return "0000000000000000"
	data, merr := json.marshal(settings, {spec = .JSON}, context.temp_allocator)
	if merr != nil do return "0000000000000000"
	return fmt.tprintf("%016x", xxh.XXH3_64(data))
}

// The artifact key: 128-bit hash of the source bytes, seeded by everything
// else that shapes the importer's output. Same inputs -> same key, on any
// machine.
@(private = "file")
_artifact_key :: proc(content: []byte, settings: any, importer: string) -> string {
	header := fmt.tprintf("moonhug-artifact|%s|v%d|f%d|s%s",
		importer, _importer_version(importer), _ARTIFACT_FORMAT_VERSION,
		_settings_hash_hex(settings))
	seed := xxh.XXH3_64(transmute([]u8)header)
	return fmt.tprintf("%032x", xxh.XXH3_128_with_seed(content, seed))
}

@(private = "file")
_run_import :: proc(source_path: string, artifact_path: string, settings: any) -> bool {
	ext := filepath.ext(source_path)
	name := _importer_by_ext[ext] or_else ""
	if desc, ok := _importers[name]; ok && desc.run != nil {
		// Hand over the typed instance only when it IS the desc's type (a
		// stale meta importer string can disagree with the extension).
		ptr := settings.id == desc.settings_tid ? settings.data : nil
		return desc.run(source_path, artifact_path, ptr)
	}
	return false
}
