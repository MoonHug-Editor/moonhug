package editor_tests

// What a reference field's picker offers among sub-assets
// (inspector/property_drawer_pptr.odin): every sub-asset of every file
// whose type the field's `ext:` tag admits, with those of the field's own
// file first. That file is the one in scope: the scene of the object
// inspected, or the file of the sub-asset edited. A file never saved has no
// guid, so only its own fields are offered its sub-assets.

import "base:runtime"
import "core:encoding/uuid"
import "core:testing"
import "moonhug:editor/inspector"
import "moonhug:editor/subassets"
import assets "moonhug:libs/assets"
import core "moonhug:libs/core"

@(private = "file") _OWNER_A :: core.Asset_GUID{0 = 0xA1, 15 = 0x01}
@(private = "file") _OWNER_B :: core.Asset_GUID{0 = 0xB2, 15 = 0x02}
@(private = "file") _EXT :: ".subassettest"
@(private = "file") _PATH_A :: "assets/a.subassettest"
@(private = "file") _PATH_B :: "assets/b.subassettest"

@(private = "file")
_list :: proc(path: string, allocator: runtime.Allocator) -> []subassets.Sub_Asset {
	out := make([dynamic]subassets.Sub_Asset, allocator)
	switch path {
	case _PATH_A:
		append(&out, subassets.Sub_Asset{id = 5, name = "Mat A", kind = "mat"})
		append(&out, subassets.Sub_Asset{id = 6, name = "Noise A", kind = "noise"})
	case _PATH_B:
		append(&out, subassets.Sub_Asset{id = 7, name = "Mat B", kind = "mat"})
	case "":
		append(&out, subassets.Sub_Asset{id = 8, name = "Unsaved Mat", kind = "mat"})
	}
	return out[:]
}

@(private = "file")
_offers :: proc(ref: core.PPtr) -> bool {
	for c in inspector.pptr_picker_candidates() do if c.entry == ref do return true
	return false
}

@(private = "file")
_place :: proc(ref: core.PPtr) -> int {
	for c, i in inspector.pptr_picker_candidates() do if c.entry == ref do return i
	return -1
}

@(test)
test_reference_picker_offers_every_files_sub_assets_own_file_first :: proc(t: ^testing.T) {
	// Two files with sub-assets, and the provider of files never saved.
	prev_db := assets.asset_db
	defer assets.asset_db = prev_db
	assets.asset_db.guid_to_path = make(map[uuid.Identifier]string, context.temp_allocator)
	assets.asset_db.path_to_guid = make(map[string]uuid.Identifier, context.temp_allocator)
	assets.asset_db.guid_to_path[uuid.Identifier(_OWNER_A)] = _PATH_A
	assets.asset_db.guid_to_path[uuid.Identifier(_OWNER_B)] = _PATH_B
	assets.asset_db.path_to_guid[_PATH_A] = uuid.Identifier(_OWNER_A)
	assets.asset_db.path_to_guid[_PATH_B] = uuid.Identifier(_OWNER_B)

	prev_no_file, had_no_file := subassets.find(subassets.NO_FILE)
	subassets.unregister(subassets.NO_FILE)
	provider := subassets.Provider{list = _list}
	subassets.register(_EXT, provider)
	subassets.register(subassets.NO_FILE, provider)
	defer {
		subassets.unregister(_EXT)
		subassets.unregister(subassets.NO_FILE)
		if had_no_file do subassets.register(subassets.NO_FILE, prev_no_file)
	}

	prev_scope, prev_filter := inspector.sub_asset_scope, inspector.current_field_ext_filter
	defer {
		inspector.sub_asset_scope = prev_scope
		inspector.current_field_ext_filter = prev_filter
	}
	inspector.current_field_ext_filter = "mat"
	mat_a := core.PPtr{guid = _OWNER_A, local_id = 5}
	noise_a := core.PPtr{guid = _OWNER_A, local_id = 6}
	mat_b := core.PPtr{guid = _OWNER_B, local_id = 7}
	mat_unsaved := core.PPtr{local_id = 8}

	// A file asset's field: every file's sub-assets, by path.
	inspector.sub_asset_scope = {}
	testing.expect(t, _offers(mat_a) && _offers(mat_b), "a field of any file is offered every file's sub-assets")
	testing.expect(t, !_offers(noise_a), "a type the field's tag does not admit is not offered")
	testing.expect(t, _place(mat_a) < _place(mat_b), "without a file in scope they are in path order")
	testing.expect(t, inspector.sub_asset_in_scope(mat_a) && inspector.sub_asset_in_scope(mat_b), "and any can be dropped")
	testing.expect(t, !_offers(mat_unsaved) && !inspector.sub_asset_in_scope(mat_unsaved), "one of a file never saved has no guid to be named by from outside")

	// An object of file B: B's own come first, A's after.
	inspector.sub_asset_scope = {set = true, owner = _OWNER_B}
	testing.expect(t, _offers(mat_a) && _offers(mat_b), "both files' materials are offered")
	testing.expect(t, _place(mat_b) < _place(mat_a), "the field's own file comes first")

	// The tag decides the type.
	inspector.current_field_ext_filter = "png,noise"
	testing.expect(t, _offers(noise_a) && !_offers(mat_a), "a texture field takes a file's noise map")

	// A file never saved: its own fields are offered its sub-assets, first.
	inspector.current_field_ext_filter = "mat"
	inspector.sub_asset_scope = {set = true}
	testing.expect(t, _offers(mat_unsaved) && inspector.sub_asset_in_scope(mat_unsaved), "a file never saved offers its own")
	testing.expect(t, _place(mat_unsaved) < _place(mat_a), "before the project's")
	s, found := subassets.get(mat_unsaved)
	testing.expect(t, found && s.name == "Unsaved Mat", "and its reference resolves to a name")
}
