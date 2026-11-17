package editor_tests

// Per-asset user settings (libs/core/per_asset.odin): an entry per asset by
// its guid, saved with the user settings, dropped when the asset leaves the
// project or is gone when the editor saves.

import "base:runtime"
import "core:encoding/json"
import "core:testing"
import core "moonhug:libs/core"

@(private = "file")
_Probe :: struct {
	x: int,
}

// Package vars, as a @(user_settings) var is: the registry keeps their
// addresses for the rest of the run.
@(private = "file")
_values: core.Per_Asset(_Probe)
@(private = "file")
_lists: core.Per_Asset([dynamic]i64)

@(private = "file")
_A :: core.Asset_GUID{0 = 0xA1}
@(private = "file")
_B :: core.Asset_GUID{0 = 0xB2}

@(test)
test_per_asset_keeps_an_entry_per_asset_while_the_asset_exists :: proc(t: ^testing.T) {
	testing.expect(t, core.per_asset_get(&_values, _A) == nil, "no entry before one is made")
	testing.expect(t, core.per_asset_entry(&_values, {}) == nil, "no asset, no entry")
	core.per_asset_entry(&_values, _A).x = 7
	core.per_asset_entry(&_values, _B).x = 8
	testing.expect_value(t, core.per_asset_get(&_values, _A).x, 7)
	testing.expect_value(t, core.per_asset_entry(&_values, _A).x, 7)
	append(core.per_asset_entry(&_lists, _A), 1, 2)
	append(core.per_asset_entry(&_lists, _B), 3)

	// Loading registers a var, with or without a file to read.
	core.user_settings_load("Per Asset Test No File", &_values)
	core.user_settings_load("Per Asset Test No File", &_lists)

	// The asset leaves the project: every Per_Asset forgets it.
	core.per_asset_drop_all(_A)
	testing.expect(t, core.per_asset_get(&_values, _A) == nil, "A's value is dropped")
	testing.expect(t, core.per_asset_get(&_lists, _A) == nil, "and its list")
	testing.expect_value(t, core.per_asset_get(&_values, _B).x, 8)

	// Before the save, entries of assets the project no longer has go.
	core.per_asset_entry(&_values, _A).x = 9
	core.per_asset_prune(proc(guid: core.Asset_GUID) -> bool { return guid == _A })
	testing.expect_value(t, core.per_asset_get(&_values, _A).x, 9)
	testing.expect(t, core.per_asset_get(&_values, _B) == nil, "B is gone from the project")
	testing.expect(t, core.per_asset_get(&_lists, _B) == nil, "from every Per_Asset")

	core.per_asset_drop(&_values, _A)
	testing.expect_value(t, len(_values.entries), 0)
	testing.expect_value(t, len(_lists.entries), 0)
}

@(test)
test_per_asset_saves_as_an_object_by_guid :: proc(t: ^testing.T) {
	saved: core.Per_Asset([dynamic]i64)
	defer {
		core.per_asset_drop(&saved, _A)
		delete(saved.entries)
	}
	append(core.per_asset_entry(&saved, _A), 4, 5)
	text, merr := json.marshal(saved, {spec = .JSON}, context.temp_allocator)
	if !testing.expect_value(t, merr, nil) do return
	testing.expect_value(t, string(text), `{"entries":{"a1000000-0000-0000-0000-000000000000":[4,5]}}`)

	loaded: core.Per_Asset([dynamic]i64)
	defer {
		core.per_asset_drop(&loaded, _A)
		delete(loaded.entries)
	}
	uerr := json.unmarshal(text, &loaded, allocator = runtime.default_allocator())
	if !testing.expect_value(t, uerr, nil) do return
	list := core.per_asset_get(&loaded, _A)
	if !testing.expect(t, list != nil, "the entry comes back by its guid") do return
	testing.expect_value(t, len(list), 2)
	testing.expect_value(t, list[1], 5)
}
