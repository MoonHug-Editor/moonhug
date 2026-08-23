package asset_pipeline

// The AssetDB's scan/refresh machinery — editor-side, like the import
// drivers: a game binary runs the catalog pipeline only (app.odin boots from
// library/catalog.json or an export) and never scans assets/ or mints metas.
// Storage and lookups (guid<->path maps, root-info index, meta primitives)
// stay in the engine; this file is the driver that fills them from the tree.

import "core:os"
import "core:path/filepath"
import "core:strings"
import "moonhug:engine"
import "moonhug:engine/log"

// Incremental refresh (Unity model): enumerate the tree (stat only), diff
// against file_state, and process only the deltas — new assets get metas +
// registration, changed scene assets re-index, deleted assets unregister and
// their orphaned metas are removed. Renames arrive as delete+create; the meta
// travels with the file (project view moves it), so the guid stays stable.
asset_db_refresh :: proc() {
	if engine.asset_db.pipeline == .Catalog do return
	walk: _Db_Walk
	walk.files = make(map[string]engine.Asset_File_Stamp, context.temp_allocator)
	walk.metas = make([dynamic]string, context.temp_allocator)
	_db_walk(engine.asset_db.root_path, &walk)
	// Installed packages: each packages/<name>/assets is a further root,
	// scanned by the same machinery (docs/Plugins.md).
	for root in engine.asset_db_package_roots() {
		_db_walk(root.assets_path, &walk)
	}

	created, modified, deleted: int

	// Deletions. Collect first — removing while iterating is unsafe.
	removed := make([dynamic]string, context.temp_allocator)
	for path in engine.asset_db.file_state {
		if path not_in walk.files {
			append(&removed, path)
		}
	}
	for path in removed {
		engine._asset_removed(path)
		old_key, _ := delete_key(&engine.asset_db.file_state, path)
		delete(old_key)
		deleted += 1
	}

	// Creations and modifications: REGISTER first, INDEX second. Indexing a
	// variant flattens it, which resolves its BASE by guid->path — if the base
	// hasn't been registered yet (map iteration order is random), the flatten
	// fails and the variant silently drops from the index for that run.
	changed := make([dynamic]string, context.temp_allocator)
	for path, stamp in walk.files {
		old, existed := engine.asset_db.file_state[path]
		if !existed {
			_ensure_meta(path)
			engine.asset_db.file_state[strings.clone(path)] = stamp
			append(&changed, path)
			created += 1
		} else if old != stamp {
			_ensure_meta(path) // re-reads the meta; guid stays stable
			engine.asset_db.file_state[path] = stamp // key exists; stored key is reused
			append(&changed, path)
			modified += 1
		}
	}
	for path in changed {
		engine._reindex_if_scene(path)
		engine.material_path_changed(path) // externally edited .mat: drop the cache entry
		engine.shader_path_changed(path)   // edited .glsl: evict (the hook below reimports)
		for hook in engine._path_changed_hooks do hook(path)
	}

	// Orphaned metas: a .meta whose asset (file or folder) is gone.
	for meta in walk.metas {
		asset_path := strings.trim_suffix(meta, ".meta")
		if asset_path not_in walk.files {
			os.remove(meta)
			log.infof("[AssetDB] Removed orphaned meta: %s", meta)
		}
	}

	if created + modified + deleted > 0 {
		// Through the log package: visible in the editor console/status bar,
		// not just the terminal.
		log.infof("[AssetDB] Refreshed: +%d ~%d -%d (%d assets)", created, modified, deleted, len(engine.asset_db.path_to_guid))
		// Keep the in-place catalog current (asset_catalog_auto): every app
		// run and every run config stages from it.
		engine._asset_catalog_auto_write()
	}
}

_Db_Walk :: struct {
	files: map[string]engine.Asset_File_Stamp, // temp; folders carry a zero stamp
	metas: [dynamic]string,                    // temp
}

_db_walk :: proc(dir_path: string, walk: ^_Db_Walk) {
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
			walk.files[full_path] = {}
			_db_walk(full_path, walk)
		} else if strings.has_suffix(entry.name, ".meta") {
			append(&walk.metas, full_path)
		} else {
			walk.files[full_path] = {mtime = entry.modification_time, size = entry.size}
		}
	}
}

@(private = "file")
_ensure_meta :: proc(asset_path: string) {
	meta_path := strings.concatenate({asset_path, ".meta"})
	defer delete(meta_path)

	if guid, ok := engine._read_meta(meta_path); ok {
		engine._register_asset(asset_path, guid)
	} else {
		guid := engine._generate_guid()
		engine._write_meta(meta_path, guid)
		engine._register_asset(asset_path, guid)
	}

	// Upgrade to an importer meta (guid + importer + settings) — the import
	// driver is this same package now.
	asset_pipeline_ensure_import_meta(asset_path)
}
