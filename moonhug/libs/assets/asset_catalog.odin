package assets

// The engine's half of the asset catalog (format, build and export live in
// moonhug:libs/catalog, a leaf package run configs import): the catalog
// pipeline. The app run with --catalog=<path> loads a catalog INSTEAD of
// scanning assets/: the guid<->path maps, the artifact index and baked import
// settings come from the file, refresh no-ops, runtime imports are refused,
// and the exported boot scene is the default scene. A run config builds the
// catalog from the project's files right before it runs or exports the game
// (catalog.build), so there is no editor-written copy to go stale.

import "core:encoding/uuid"
import "core:os"
import "core:path/filepath"
import "core:fmt"
import "core:strings"
import "moonhug:libs/catalog"
import "moonhug:libs/log"
import core "moonhug:libs/core"

// The editor's in-place catalog, under the library root. Temp-allocated.
asset_catalog_path :: proc() -> string {
	return fmt.tprintf("%s/catalog.json", library_dir())
}

// Catalog pipeline init: fill the AssetDB, the artifact index and the baked settings
// from the catalog — no scan, no meta reads. The picker indexes (root_info,
// assets_by_type) stay empty, they serve editor UI only.
asset_db_init_from_catalog :: proc(catalog_path := "") -> bool {
	catalog_path := catalog_path
	if catalog_path == "" do catalog_path = asset_catalog_path()
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
	asset_db.subs = make(map[uuid.Identifier]Sub_Asset_Ref)
	asset_db.root_info = make(map[core.Asset_GUID]Asset_Root_Info)
	asset_db.assets_by_type = make(map[core.TypeKey][dynamic]core.PPtr)
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
			asset_db.boot_scene = core.Asset_GUID(guid)
		}
	}

	for guid_str, entry in cf.assets {
		if entry.sub != 0 do continue // second pass, once every owner is in
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
	for guid_str, entry in cf.assets {
		if entry.sub == 0 do continue
		guid, perr := uuid.read(guid_str)
		if perr != nil do continue
		p := base == "" ? entry.path : strings.concatenate({base, "/", entry.path}, context.temp_allocator)
		owner, has := asset_db.path_to_guid[p]
		if !has {
			log.errorf("[Catalog] sub-asset %s names owner %q, which is not in the catalog — skipped", guid_str, entry.path)
			continue
		}
		// `kind` serves the editor's picker only, and a game has no picker.
		_register_sub(p, core.Asset_GUID(owner), core.Asset_GUID(guid), core.Local_ID(entry.sub), "")
	}
	log.infof("[Catalog] catalog pipeline from %s (%d assets)", catalog_path, len(cf.assets))
	return true
}

// The exported boot scene ({} outside a catalog pipeline or when none was pinned).
asset_db_boot_scene :: proc() -> core.Asset_GUID {
	return asset_db.boot_scene
}
