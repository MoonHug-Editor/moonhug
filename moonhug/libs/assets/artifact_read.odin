package assets

// Reading artifacts. Every loader reads its asset's files through these procs,
// so a missing or bad file is handled one way for every asset type
// (docs/core/AssetPipeline.md "Reading artifacts"):
// - the editor imports an asset whose main artifact is missing on the spot,
//   and reimports a bad file once (an older format after an artifact bump).
//   A missing sub-asset file beside a present main artifact is reported, not
//   imported: the import that wrote the main artifact is the one that would
//   have written it
// - a reimport a read asked for that leaves the file missing or bad is not
//   asked for again until something else reimports the asset, so two broken
//   files of one asset never reimport it in turn every frame
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

// The files that failed, reported once each. Every artifact-file failure of
// every loader is recorded here and nowhere else (a loader's own map holds
// only failures that are not about a file, such as a GPU upload). Cleared per
// asset on reimport and whole when the database shuts down.
@(private = "file")
_artifact_failed: map[core.PPtr]bool

// Assets a reimport asked for by a read did not repair: the file stayed
// missing or bad. A read does not ask again until another reimport of the
// asset (an edit, an Apply) clears the entry. Without it, a reimport for one
// broken file clears the mark of another broken file of the same asset, whose
// next read reimports again, every frame.
@(private = "file")
_artifact_reimport_futile: map[core.Asset_GUID]bool

// The asset a read is reimporting right now: its own reimport must not clear
// its futile entry.
@(private = "file")
_artifact_reimporting: core.Asset_GUID

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
	// Only a missing main artifact asks for an import. A sub-asset file the
	// import should have written beside a present main artifact would not
	// appear by importing again.
	main, main_ok := _artifact_file_path(guid, 0)
	main_missing := !main_ok || !os.exists(main)
	if import_missing && main_missing && _artifact_reimport(guid, source) {
		if p, pok := _artifact_file_path(guid, sub); pok && os.exists(p) do return p, true
		_artifact_reimport_futile_mark(guid)
	}
	p, _ := _artifact_file_path(guid, sub)
	if asset_db.exported {
		named := sub == 0 ? "the asset itself" : fmt.tprintf("sub-asset %d", sub)
		_artifact_report(ref, fmt.tprintf("%s is not in this export: no reference the export followed names %s. Reference it with a PPtr, or put the asset under a resources folder", _artifact_name(source, sub), named))
	} else if import_missing && !main_missing && _import_request != nil && asset_db.pipeline != .Catalog {
		_artifact_report(ref, fmt.tprintf("%s: %s is missing, reimport the asset to write it again", _artifact_name(source, sub), p))
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
	if _artifact_reimport(guid, source) {
		data = artifact_read(guid, sub) or_return
		if parse(data, out) do return true
		_artifact_reimport_futile_mark(guid)
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

// An import rewrote the asset's files: each of them gets its next try. A
// reimport other than the one a read is running also lets reads ask for
// reimports of the asset again.
@(private)
_artifact_failed_forget :: proc(guid: core.Asset_GUID) {
	if guid != _artifact_reimporting do delete_key(&_artifact_reimport_futile, guid)
	if len(_artifact_failed) == 0 do return
	gone := make([dynamic]core.PPtr, context.temp_allocator)
	for ref in _artifact_failed do if ref.guid == guid do append(&gone, ref)
	for ref in gone do delete_key(&_artifact_failed, ref)
}

@(private)
_artifact_failed_reset :: proc() {
	delete(_artifact_failed)
	_artifact_failed = nil
	delete(_artifact_reimport_futile)
	_artifact_reimport_futile = nil
}

// A forced reimport of the asset for a read, unless an earlier one left a file
// of it broken. true when the import ran.
@(private = "file")
_artifact_reimport :: proc(guid: core.Asset_GUID, source: string) -> bool {
	if _import_request == nil || guid in _artifact_reimport_futile do return false
	_artifact_reimporting = guid
	defer _artifact_reimporting = {}
	return asset_pipeline_request_import(source, force = true)
}

@(private = "file")
_artifact_reimport_futile_mark :: proc(guid: core.Asset_GUID) {
	context.allocator = runtime.default_allocator()
	_artifact_reimport_futile[guid] = true
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
