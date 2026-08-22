package engine

// The engine's live halves of the asset catalog (format + export live in
// moonhug:engine/catalog, a leaf package run configs can import):
//
// - the editor maintains library/catalog.json AUTOMATICALLY: with
//   asset_catalog_auto set (editor init), every import pass and refresh
//   rewrites it. Nothing user-facing — it is a byproduct like
//   artifact_db.json. Run configs stage build data from it
//   (catalog.export_from) without a live AssetDB.
// - the catalog pipeline (the app run with --catalog=<path>) loads a catalog
//   INSTEAD of scanning assets/: the guid<->path maps, the artifact index
//   and baked import settings come from the file, refresh no-ops, runtime
//   imports are refused, and the exported boot scene is the default scene.

import "core:encoding/json"
import "core:encoding/uuid"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "catalog"
import "log"

ASSET_CATALOG_PATH :: "library/catalog.json"

// Set by the editor: import passes and refreshes rewrite the in-place
// catalog so it is always current. The app never sets it (a lazily-imported
// dev run would overwrite the editor's complete catalog with a partial one).
asset_catalog_auto: bool

_asset_catalog_auto_write :: proc() {
	if asset_catalog_auto && asset_db.pipeline == .Import {
		asset_catalog_write()
	}
}

// Snapshot the live AssetDB + artifact index into `path`: per asset its
// source path, artifact key, and import settings baked as JSON text (typed
// instance marshaled — an exported data dir ships no .meta files).
asset_catalog_write :: proc(path: string = ASSET_CATALOG_PATH) -> bool {
	cf := catalog.File{version = catalog.VERSION}
	cf.assets = make(map[string]catalog.Entry, len(asset_db.guid_to_path), context.temp_allocator)
	for guid, asset_path in asset_db.guid_to_path {
		entry := catalog.Entry{path = asset_path}
		if key, has := asset_pipeline_artifact_key(Asset_GUID(guid)); has {
			entry.artifact = key
		}
		if settings, sok := asset_pipeline_get_settings(asset_path, context.temp_allocator); sok {
			if blob, merr := json.marshal(settings, {spec = .JSON}, context.temp_allocator); merr == nil {
				entry.settings = string(blob)
			}
		}
		cf.assets[uuid.to_string(guid, context.temp_allocator)] = entry
	}
	if !catalog.save(&cf, path) do return false
	log.infof("[Catalog] wrote %s (%d assets)", path, len(cf.assets))
	return true
}

// Catalog pipeline init: fill the AssetDB, the artifact index and the baked settings
// from the catalog — no scan, no meta reads. The picker indexes (root_info,
// assets_by_type) stay empty, they serve editor UI only.
asset_db_init_from_catalog :: proc(catalog_path: string = ASSET_CATALOG_PATH) -> bool {
	data, read_err := os.read_entire_file(catalog_path, context.temp_allocator)
	if read_err != nil {
		log.errorf("[Catalog] cannot read %s", catalog_path)
		return false
	}
	cf, pok := catalog.parse(data)
	if !pok {
		log.errorf("[Catalog] cannot parse %s", catalog_path)
		return false
	}
	if cf.version != catalog.VERSION {
		log.errorf("[Catalog] %s is version %d, this build reads %d — re-export it",
			catalog_path, cf.version, catalog.VERSION)
		return false
	}

	asset_db.pipeline = .Catalog
	asset_db.guid_to_path = make(map[uuid.Identifier]string)
	asset_db.path_to_guid = make(map[string]uuid.Identifier)
	asset_db.root_info = make(map[Asset_GUID]Asset_Root_Info)
	asset_db.assets_by_type = make(map[TypeKey][dynamic]PPtr)
	asset_db.file_state = make(map[string]Asset_File_Stamp)

	// A relocatable catalog (an export) resolves everything relative to its
	// own directory: entry paths get the prefix, artifacts come from its
	// artifacts/ fan-out instead of the working tree's library.
	base := ""
	if cf.relocatable {
		{
			context.allocator = context.temp_allocator
			base = filepath.dir(catalog_path)
		}
		_artifact_dir_set(strings.concatenate({base, "/artifacts"}, context.temp_allocator))
	}

	if cf.boot_scene != "" {
		if guid, perr := uuid.read(cf.boot_scene); perr == nil {
			asset_db.boot_scene = Asset_GUID(guid)
		}
	}

	for guid_str, entry in cf.assets {
		guid, perr := uuid.read(guid_str)
		if perr != nil {
			log.errorf("[Catalog] bad guid %q — skipped", guid_str)
			continue
		}
		p := base == "" ? strings.clone(entry.path) : strings.concatenate({base, "/", entry.path})
		asset_db.guid_to_path[guid] = p
		asset_db.path_to_guid[p] = guid
		if entry.artifact != "" {
			_artifact_index_seed(guid, entry.artifact)
		}
		if entry.settings != "" {
			_catalog_settings_set(guid, entry.settings)
		}
	}
	log.infof("[Catalog] catalog pipeline from %s (%d assets)", catalog_path, len(cf.assets))
	return true
}

// The exported boot scene ({} outside a catalog pipeline or when none was pinned).
asset_db_boot_scene :: proc() -> Asset_GUID {
	return asset_db.boot_scene
}
