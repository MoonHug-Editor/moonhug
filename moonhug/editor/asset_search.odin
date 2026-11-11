package editor

// Finds assets by a query. The Project window's search and the command
// palette's Assets mode both list what asset_search finds, so a word means
// the same in both. The asset database answers every part of a query: a
// search opens no file. Every word must match:
//   - a plain word: part of the file's or the folder's name, by the caller's
//     name test. One with a slash matches the path: "ui/" is a folder's assets
//   - "t:material": the asset's type. Part of the file's extension ("mat"),
//     of its type's name in Assets > Create ("Material", "NoiseMap"), or of
//     its importer's name ("texture", "mesh", "audio"). "t:folder" is a folder
//   - "c:enemy": a scene file whose root object has a component of that type
//     (the database's root-component index, the one the object picker uses)
//   - a "$" at the end of a tagged word marks the end of the name:
//     "t:mat$" is not "material"
// A sub-asset the database lists (a scene file's) is a hit of its own, by its
// name and its type.

import "base:runtime"
import "core:path/filepath"
import "core:strings"
import asset_pipeline "moonhug:editor/assets"
import "moonhug:editor/widgets"
import assets "moonhug:libs/assets"
import core "moonhug:libs/core"
import "subassets"

// One asset a query found. Its strings are the database's: valid this frame.
Asset_Hit :: struct {
    path:     string,
    is_dir:   bool,
    sub:      core.Local_ID, // not 0: the sub-asset of the file with this id
    sub_name: string,
    sub_kind: string,
}

// Whether every term matches the name: widgets.search_match, or the command
// palette's ranked test.
Asset_Name_Match :: proc(name: string, terms: []string) -> bool

// Adds every asset that matches `query` to `hits`, in no order.
asset_search :: proc(query: string, name_match: Asset_Name_Match, hits: ^[dynamic]Asset_Hit) {
    plain, tagged := widgets.search_split(widgets.search_terms(query))
    names := make([dynamic]string, 0, len(plain), context.temp_allocator)
    paths := make([dynamic]string, 0, len(plain), context.temp_allocator)
    for term in plain {
        if strings.contains_any(term, "/\\") do append(&paths, term)
        else do append(&names, term)
    }
    types := make([dynamic]_Asset_Tag, 0, len(tagged), context.temp_allocator)
    // One set per "c:" word: the scene files whose root has such a component.
    with_component := make([dynamic]map[core.Asset_GUID]bool, 0, len(tagged), context.temp_allocator)
    for term in tagged {
        if word, exact, ok := widgets.search_tag(term, "t:"); ok {
            append(&types, _Asset_Tag{word, exact})
        } else if word, exact, ok := widgets.search_tag(term, "c:"); ok {
            set := make(map[core.Asset_GUID]bool, context.temp_allocator)
            for key, refs in assets.asset_db.assets_by_type {
                tid := core.get_typeid_by_type_key(key)
                if tid == nil do continue
                named, is_named := type_info_of(tid).variant.(runtime.Type_Info_Named)
                if !is_named || !widgets.search_tag_match(named.name, word, exact) do continue
                for ref in refs do set[ref.guid] = true
            }
            append(&with_component, set)
        } else {
            // A tag no asset has: nothing matches.
            return
        }
    }

    for path, raw_guid in assets.asset_db.path_to_guid {
        guid := core.Asset_GUID(raw_guid)
        is_dir := assets.asset_db_is_dir(path)
        in_path := true
        lower_path := strings.to_lower(path, context.temp_allocator) if len(paths) > 0 else ""
        for term in paths do if !strings.contains(lower_path, term) {
            in_path = false
            break
        }
        if !in_path do continue

        // The file or folder itself.
        file_hit := name_match(filepath.base(path), names[:])
        for set in with_component do if !set[guid] {
            file_hit = false
            break
        }
        if file_hit && len(types) > 0 {
            if is_dir {
                file_hit = _asset_types_match(types[:], {"folder"})
            } else {
                ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
                kind_names := _asset_kind_type_names(strings.trim_prefix(ext, "."))
                file_hit = _asset_types_match(types[:], {kind_names[0], kind_names[1], asset_pipeline.importer_for_extension(ext)})
            }
        }
        if file_hit do append(hits, Asset_Hit{path = path, is_dir = is_dir})

        // Its sub-assets. None has a root object, so a "c:" word matches none.
        if len(with_component) > 0 do continue
        for sub in assets.asset_db_sub_assets(guid) {
            if !name_match(sub.name, names[:]) do continue
            kind_names := _asset_kind_type_names(sub.kind)
            if !_asset_types_match(types[:], kind_names[:]) do continue
            append(hits, Asset_Hit{path = path, sub = sub.id, sub_name = sub.name, sub_kind = sub.kind})
        }
    }
}

@(private = "file")
_Asset_Tag :: struct {
    word:  string,
    exact: bool,
}

// Whether every "t:" word matches one of the type names.
@(private = "file")
_asset_types_match :: proc(types: []_Asset_Tag, type_names: []string) -> bool {
    for t in types {
        found := false
        for n in type_names do if n != "" && widgets.search_tag_match(n, t.word, t.exact) {
            found = true
            break
        }
        if !found do return false
    }
    return true
}

// What "t:" matches for an asset kind ("mat"): the kind, and its type's name
// in Assets > Create without its spaces ("Material", "NoiseMap").
@(private = "file")
_asset_kind_type_names :: proc(kind: string) -> [2]string {
    title, _ := strings.remove_all(subassets.kind_title(kind), " ", context.temp_allocator)
    return {kind, title}
}
