package assets

// Reading artifacts. Every loader reads its asset's files through these procs,
// so a missing or bad file is handled one way for every asset type
// (docs/core/AssetPipeline.md "Reading artifacts"):
// - the editor imports a missing file on the spot, and reimports a bad one
//   once (an older format after an artifact bump)
// - a game has no importer, so there a missing or bad file is a load error.
//   It is logged once, naming the asset, the sub-asset and the file. In an
//   export, a missing file was left out because nothing referenced it, and
//   the message says so
// - a file that failed is not read again until its asset reimports, so a
//   loader called every frame costs nothing and logs nothing more
//
// A file is named by the asset's guid and a local id: 0 for the asset itself
// (its main artifact), else the sub-asset's id (artifact_sub_path).

import "base:runtime"
import "core:encoding/uuid"
import "core:fmt"
import "core:os"
import core "moonhug:libs/core"
import "moonhug:libs/log"

// The files that failed, reported once each. Cleared per asset on reimport
// and whole when the database shuts down.
@(private = "file")
_artifact_failed: map[core.PPtr]bool

// The file of an asset (sub 0) or of one of its sub-assets, present on disk.
// `import_missing` false is for files something other than the importer makes, such
// as the hulls of a convex decomposition: they are reported when missing,
// never imported.
artifact_file :: proc(guid: core.Asset_GUID, sub: core.Local_ID = 0, import_missing := true) -> (path: string, ok: bool) {
	if core.asset_guid_is_empty(guid) do return "", false
	ref := core.PPtr{guid = guid, local_id = sub}
	if ref in _artifact_failed do return "", false
	if p, pok := _artifact_file_path(guid, sub); pok && os.exists(p) do return p, true

	source, sok := asset_db_get_path(uuid.Identifier(guid))
	if !sok {
		id := uuid.to_string(uuid.Identifier(guid), context.temp_allocator)
		if asset_db.exported {
			_artifact_report(ref, fmt.tprintf("asset %s is not in this export: no reference the export followed names it. Reference it, or put it under a resources folder", id))
		} else {
			_artifact_report(ref, fmt.tprintf("no asset has guid %s", id))
		}
		return "", false
	}
	if import_missing && asset_pipeline_request_import(source, force = true) {
		if p, pok := _artifact_file_path(guid, sub); pok && os.exists(p) do return p, true
	}
	p, _ := _artifact_file_path(guid, sub)
	if asset_db.exported {
		named := sub == 0 ? "the asset itself" : fmt.tprintf("sub-asset %d", sub)
		_artifact_report(ref, fmt.tprintf("%s is not in this export: no reference the export followed names %s. Reference it with a PPtr, or put the asset under a resources folder", _artifact_name(source, sub), named))
	} else {
		_artifact_report(ref, fmt.tprintf("%s: %s is missing", _artifact_name(source, sub), p))
	}
	return "", false
}

// The file's bytes, temp-allocated.
artifact_read :: proc(guid: core.Asset_GUID, sub: core.Local_ID = 0, import_missing := true) -> (data: []byte, ok: bool) {
	path := artifact_file(guid, sub, import_missing) or_return
	read_err: os.Error
	data, read_err = os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		source, _ := asset_db_get_path(uuid.Identifier(guid))
		_artifact_report(core.PPtr{guid = guid, local_id = sub}, fmt.tprintf("%s: %s is unreadable (%v)", _artifact_name(source, sub), path, read_err))
		return nil, false
	}
	return data, true
}

// Read and parse in one: `parse` fills `out` from the bytes. Bytes that do not
// parse get one forced reimport in the editor, then a report naming `what`
// the file should have been ("mesh", "clip").
artifact_load :: proc(guid: core.Asset_GUID, sub: core.Local_ID, what: string, out: ^$T, parse: proc(data: []byte, out: ^T) -> bool) -> bool {
	data := artifact_read(guid, sub) or_return
	if parse(data, out) do return true
	source, _ := asset_db_get_path(uuid.Identifier(guid))
	if asset_pipeline_request_import(source, force = true) {
		data = artifact_read(guid, sub) or_return
		if parse(data, out) do return true
	}
	p, _ := _artifact_file_path(guid, sub)
	_artifact_report(core.PPtr{guid = guid, local_id = sub}, fmt.tprintf("%s: %s does not load as a %s", _artifact_name(source, sub), p, what))
	return false
}

// A loader's own reason a file cannot be used, such as a clip id the model
// does not list: reported once, and the file fails until the asset reimports.
artifact_fail :: proc(guid: core.Asset_GUID, sub: core.Local_ID, why: string) {
	ref := core.PPtr{guid = guid, local_id = sub}
	if ref in _artifact_failed do return
	source, _ := asset_db_get_path(uuid.Identifier(guid))
	_artifact_report(ref, fmt.tprintf("%s: %s", _artifact_name(source, sub), why))
}

// A file made outside the import (the hulls of a convex decomposition) is on
// disk now: a failure recorded before it existed no longer holds.
artifact_written :: proc(guid: core.Asset_GUID, sub: core.Local_ID = 0) {
	delete_key(&_artifact_failed, core.PPtr{guid = guid, local_id = sub})
}

// An import rewrote the asset's files: each of them gets its next try.
@(private)
_artifact_failed_forget :: proc(guid: core.Asset_GUID) {
	if len(_artifact_failed) == 0 do return
	gone := make([dynamic]core.PPtr, context.temp_allocator)
	for ref in _artifact_failed do if ref.guid == guid do append(&gone, ref)
	for ref in gone do delete_key(&_artifact_failed, ref)
}

@(private)
_artifact_failed_reset :: proc() {
	delete(_artifact_failed)
	_artifact_failed = nil
}

@(private = "file")
_artifact_report :: proc(ref: core.PPtr, message: string) {
	context.allocator = runtime.default_allocator()
	_artifact_failed[ref] = true
	log.errorf("[Artifact] %s", message)
}

// "<source>" for the asset itself, "<source> (sub-asset <id>)" for one of its
// sub-assets.
@(private = "file")
_artifact_name :: proc(source: string, sub: core.Local_ID) -> string {
	if sub == 0 do return source
	return fmt.tprintf("%s (sub-asset %d)", source, sub)
}

// The path of the file, whether or not it exists. ok=false when the asset has
// no artifact entry yet.
@(private = "file")
_artifact_file_path :: proc(guid: core.Asset_GUID, sub: core.Local_ID) -> (path: string, ok: bool) {
	main := asset_pipeline_artifact_path(guid) or_return
	if sub == 0 do return main, true
	return artifact_sub_path(main, sub, context.temp_allocator), true
}
