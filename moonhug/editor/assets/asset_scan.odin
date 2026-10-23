package asset_pipeline

// The AssetDB's scan/refresh machinery — editor-side, like the import
// drivers: a game binary runs the catalog pipeline only (app.odin boots from
// library/catalog.json or an export) and never scans assets/ or mints metas.
// Storage and lookups (guid<->path maps, root-info index, meta primitives)
// live in the libs package moonhug:libs/assets. This file is the driver
// that fills them from the tree.

import "core:encoding/uuid"
import "core:os"
import "core:path/filepath"
import "core:strings"
import core "moonhug:libs/core"
import assets "moonhug:libs/assets"
import "moonhug:libs/log"

// Incremental refresh (Unity model): enumerate the tree (stat only), diff
// against file_state, and process only the deltas — new assets get metas +
// registration, changed scene assets re-index, deleted assets unregister and
// their orphaned metas are removed. Renames arrive as delete+create; the meta
// travels with the file (project view moves it), so the guid stays stable.
// A changed asset, its source or its .meta, is reimported here when it has an
// importer, so the editor matches the files after a git checkout or an edit
// in another program. The import's freshness check (mtime, size, settings
// hash) makes that a no-op when nothing an import reads changed. New assets
// import when first needed, as at startup.
asset_db_refresh :: proc() {
	if assets.asset_db.pipeline == .Catalog do return
	walk: _Db_Walk
	walk.files = make(map[string]assets.Asset_File_Stamp, context.temp_allocator)
	walk.metas = make([dynamic]string, context.temp_allocator)
	_db_walk(assets.asset_db.root_path, &walk)
	// Installed packages: each packages/<name>/assets is a further root,
	// scanned by the same machinery (docs/core/Plugins.md).
	for root in assets.asset_db_package_roots() {
		_db_walk(root.assets_path, &walk)
	}

	created, modified, deleted: int
	// The stamps as they were, to tell a modified asset from a created one.
	before := make(map[string]assets.Asset_File_Stamp, len(assets.asset_db.file_state), context.temp_allocator)
	for path, stamp in assets.asset_db.file_state do before[path] = stamp

	// Deletions. Collect first — removing while iterating is unsafe.
	removed := make([dynamic]string, context.temp_allocator)
	for path in assets.asset_db.file_state {
		if path not_in walk.files {
			append(&removed, path)
		}
	}
	// A rename arrives as a removal plus a creation under the same guid, so
	// whether an asset is really gone is only known after the creations below.
	Removed :: struct {
		guid: core.Asset_GUID,
		path: string,
	}
	gone := make([dynamic]Removed, context.temp_allocator)
	for path in removed {
		if guid, ok := assets.asset_db.path_to_guid[path]; ok {
			append(&gone, Removed{core.Asset_GUID(guid), strings.clone(path, context.temp_allocator)})
		}
		assets._asset_removed(path)
		old_key, _ := delete_key(&assets.asset_db.file_state, path)
		delete(old_key)
		deleted += 1
	}

	// Creations and modifications: REGISTER first, INDEX second. Indexing a
	// variant flattens it, which resolves its BASE by guid->path — if the base
	// hasn't been registered yet (map iteration order is random), the flatten
	// fails and the variant silently drops from the index for that run.
	changed := make([dynamic]string, context.temp_allocator)
	for path, stamp in walk.files {
		old, existed := assets.asset_db.file_state[path]
		if !existed {
			_ensure_meta(path)
			assets.asset_db.file_state[strings.clone(path)] = _with_meta_stamp(path, stamp)
			append(&changed, path)
			created += 1
		} else if old != stamp {
			_ensure_meta(path) // re-reads the meta; guid stays stable
			assets.asset_db.file_state[path] = _with_meta_stamp(path, stamp) // key exists; stored key is reused
			append(&changed, path)
			modified += 1
		}
	}
	for path in changed {
		assets.asset_db_reindex(path)
		// Cache eviction first (an edited .mat or .glsl drops its entry), then
		// the path-changed hooks (the shader hook below reimports).
		assets.asset_db_run_evict_hooks(path)
		for hook in assets._path_changed_hooks do hook(path)
	}
	// Changed assets reimport, one index write for the lot. Created ones are
	// in `changed` too and are left to import when first needed.
	if modified > 0 {
		assets._artifact_index_batch_set(true)
		for path in changed {
			if old, existed := before[path]; !existed || old == assets.asset_db.file_state[path] do continue
			if is_importable_extension(filepath.ext(path)) do _ = asset_pipeline_import_asset(path)
		}
		assets._artifact_index_batch_set(false)
		assets._artifact_index_save()
	}
	for r in gone {
		if uuid.Identifier(r.guid) in assets.asset_db.guid_to_path do continue // renamed or moved
		for hook in assets._asset_gone_hooks do hook(r.guid, r.path)
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
		log.infof("[AssetDB] Refreshed: +%d ~%d -%d (%d assets)", created, modified, deleted, len(assets.asset_db.path_to_guid))
	}
}

_Db_Walk :: struct {
	files: map[string]assets.Asset_File_Stamp, // temp; folders carry a zero stamp
	metas: [dynamic]string,                    // temp
}

_db_walk :: proc(dir_path: string, walk: ^_Db_Walk) {
	handle, err := os.open(dir_path)
	if err != nil do return
	defer os.close(handle)

	entries, read_err := os.read_dir(handle, -1, context.temp_allocator)
	if read_err != nil do return
	defer os.file_info_slice_delete(entries, context.temp_allocator)

	// The folder's metas first, so each file's stamp carries its meta's.
	metas := make(map[string]os.File_Info, context.temp_allocator)
	for entry in entries {
		if strings.has_suffix(entry.name, ".meta") do metas[entry.name] = entry
	}
	for entry in entries {
		if strings.has_prefix(entry.name, ".") do continue
		full_path, _ := filepath.join({dir_path, entry.name}, context.temp_allocator)
		if entry.type == .Directory {
			walk.files[full_path] = {}
			_db_walk(full_path, walk)
		} else if strings.has_suffix(entry.name, ".meta") {
			append(&walk.metas, full_path)
		} else {
			stamp := assets.Asset_File_Stamp{mtime = entry.modification_time, size = entry.size}
			if meta, has := metas[strings.concatenate({entry.name, ".meta"}, context.temp_allocator)]; has {
				stamp.meta_mtime, stamp.meta_size = meta.modification_time, meta.size
			}
			walk.files[full_path] = stamp
		}
	}
}

// The stamp with its .meta's as it is now: _ensure_meta may just have written
// or upgraded it, and a stamp taken before that would read as a change on the
// next refresh.
@(private = "file")
_with_meta_stamp :: proc(path: string, stamp: assets.Asset_File_Stamp) -> assets.Asset_File_Stamp {
	out := stamp
	if info, err := os.stat(strings.concatenate({path, ".meta"}, context.temp_allocator), context.temp_allocator); err == nil {
		out.meta_mtime, out.meta_size = info.modification_time, info.size
	}
	return out
}

@(private = "file")
_ensure_meta :: proc(asset_path: string) {
	meta_path := strings.concatenate({asset_path, ".meta"})
	defer delete(meta_path)

	if guid, ok := assets._read_meta(meta_path); ok {
		assets._register_asset(asset_path, guid)
	} else {
		guid := assets._generate_guid()
		assets._write_meta(meta_path, guid)
		assets._register_asset(asset_path, guid)
	}

	// Upgrade to an importer meta (guid + importer + settings) — the import
	// driver is this same package now.
	asset_pipeline_ensure_import_meta(asset_path)
}
