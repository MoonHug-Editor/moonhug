package editor_tests

// asset_search (editor/asset_search.odin): the one finder behind the Project
// window's search and the command palette's Assets mode. Both name tests give
// the same assets for the same words, and the palette's rows are what the
// finder found.

import "base:runtime"
import "core:encoding/uuid"
import "core:strings"
import "core:testing"
import "moonhug:editor"
import "moonhug:editor/command_palette"
import "moonhug:editor/widgets"
import assets "moonhug:libs/assets"
import core "moonhug:libs/core"

@(private = "file") _MAT :: "assets/ui/Button.mat"
@(private = "file") _HERO :: "assets/Hero.scene"
@(private = "file") _BARE :: "assets/Bare.scene"
@(private = "file") _ROCK :: "assets/rock.png"

// What a query finds, as "path" or "path#sub name", by one name test.
@(private = "file")
_found :: proc(query: string, name_match: editor.Asset_Name_Match) -> map[string]bool {
	hits := make([dynamic]editor.Asset_Hit, context.temp_allocator)
	editor.asset_search(query, name_match, &hits)
	out := make(map[string]bool, context.temp_allocator)
	for h in hits {
		if h.sub != 0 do out[strings.concatenate({h.path, "#", h.sub_name}, context.temp_allocator)] = true
		else do out[h.path] = true
	}
	return out
}

@(test)
test_asset_search_words_mean_the_same_in_the_project_search_and_the_palette :: proc(t: ^testing.T) {
	prev_db := assets.asset_db
	defer assets.asset_db = prev_db
	a := context.temp_allocator
	assets.asset_db.guid_to_path = make(map[uuid.Identifier]string, a)
	assets.asset_db.path_to_guid = make(map[string]uuid.Identifier, a)
	assets.asset_db.sub_assets = make(map[core.Asset_GUID][]assets.Asset_Sub_Info, a)
	assets.asset_db.assets_by_type = make(map[core.TypeKey][dynamic]core.PPtr, a)
	assets.asset_db.file_state = nil
	guids := make(map[string]core.Asset_GUID, a)
	guids[_MAT] = {0 = 1}
	guids[_HERO] = {0 = 2}
	guids[_BARE] = {0 = 3}
	guids[_ROCK] = {0 = 4}
	for path, g in guids {
		assets.asset_db.guid_to_path[uuid.Identifier(g)] = path
		assets.asset_db.path_to_guid[path] = uuid.Identifier(g)
	}
	subs := []assets.Asset_Sub_Info{{id = 7, name = "Marble", kind = "mat"}}
	assets.asset_db.sub_assets[guids[_HERO]] = subs

	// Hero's root has a component: any registered named type stands for it.
	comp: string
	for tid, key in core.typeid_to_type_key_map {
		named, is_named := type_info_of(tid).variant.(runtime.Type_Info_Named)
		if !is_named do continue
		comp = strings.to_lower(named.name, a)
		on_root := make([dynamic]core.PPtr, a)
		append(&on_root, core.PPtr{guid = guids[_HERO], local_id = 3})
		assets.asset_db.assets_by_type[key] = on_root
		break
	}
	if !testing.expect(t, comp != "", "a type is registered") do return

	MARBLE :: _HERO + "#Marble"
	for name_match, i in ([]editor.Asset_Name_Match{widgets.search_match, command_palette.matches}) {
		who := i == 0 ? "project search" : "palette"
		f := _found("marble", name_match)
		testing.expectf(t, len(f) == 1 && f[MARBLE], "%s: a name finds the scene's sub-asset, got %v", who, f)
		f = _found("t:mat", name_match)
		testing.expectf(t, len(f) == 2 && f[_MAT] && f[MARBLE], "%s: t:mat is the material file and the material sub-asset, got %v", who, f)
		f = _found("t:ma$", name_match)
		testing.expectf(t, len(f) == 0, "%s: t:ma$ is no whole type name, got %v", who, f)
		f = _found("t:png", name_match)
		testing.expectf(t, len(f) == 1 && f[_ROCK], "%s: t:png is the image, got %v", who, f)
		f = _found(strings.concatenate({"c:", comp, "$"}, a), name_match)
		testing.expectf(t, len(f) == 1 && f[_HERO], "%s: c: is the scene whose root has the component, got %v", who, f)
		f = _found(strings.concatenate({"t:scene c:", comp, "$"}, a), name_match)
		testing.expectf(t, len(f) == 1 && f[_HERO], "%s: both tags together, got %v", who, f)
		f = _found("ui/", name_match)
		testing.expectf(t, len(f) == 1 && f[_MAT], "%s: a word with a slash is part of the path, got %v", who, f)
		f = _found("x:what", name_match)
		testing.expectf(t, len(f) == 0, "%s: a tag no asset has finds nothing, got %v", who, f)
	}

	// The palette's rows are the finder's hits.
	rows := make([dynamic]command_palette.Row, a)
	editor.command_palette_assets("t:mat", &rows)
	labels := make(map[string]bool, a)
	for r in rows do labels[r.label] = true
	testing.expectf(t, len(rows) == 2 && labels["Button.mat"] && labels["Marble"], "the Assets mode lists the file and the sub-asset, got %v", labels)
}
