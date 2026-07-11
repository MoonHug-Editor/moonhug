# Object Picker

Unity-style picker popup for reference fields in the inspector. One shared
popup with **Scene** and **Project** tabs; which tabs are shown depends on
what the field's type can physically reference (see
[ReferenceHandles](ReferenceHandles.md)).

## Current state


- Unity-like field row (`_picker_field_row`, shared by all three drawers):
  label / value / [x] / [pick]. Value single-click pings, double-click
  opens/selects; [x] clears; [pick] opens the popup with a search field.
- `Ref_Local` fields (`ref:"TypeName"` tag): single **Scene** tab listing
  live objects of the target type in the loaded scene.
- `Asset_GUID` fields: single **Project** tab listing assets — all of them
  untagged, or only scene assets whose ROOT has the tagged component
  (`assets_by_type` index); drag-drop onto the value still assigns.
- `Ref` (PPtr) fields: BOTH tabs assignable. Scene pick stores
  `{local_id, guid: 0}` + live handle; Project pick assigns the index's PPtr
  (asset guid + ROOT component local_id) with an unresolved handle — game
  code treats it as optional and can instantiate by guid.
  `pick:"scene"` / `pick:"project"` tags limit which tab is assignable.
  Display and ping never need the asset loaded (AssetDB root info). No app
  component uses `Ref` yet — adopting it (e.g. a typed prefab ref) changes
  component/scene data, an app-side decision. Converting a field does NOT
  migrate old values: `{"local_id"}` data doesn't parse into
  `{"pptr":{...}}` — re-pick and save after converting.
- Ping channels: `inspector_request_ping` (hierarchy reveal + fading flash,
  selection untouched), `inspector_request_select` (select + reveal + scroll),
  `inspector_request_ping_asset` (project view reveal + flash), and
  `inspector_request_open_asset` (reveal + select + activate).
- AssetDB: `root_info` + `assets_by_type` (values are complete PPtrs), kept
  current by the incremental Unity-style `asset_db_refresh` (roadmap step 5;
  requires `serialization.init()` to have run — both editor and app init do).

## Design

### Unity reference

Unity's object picker shows Scene and Assets tabs. Scene lists live objects of
the field's type; Assets lists assets assignable to it — for component-typed
fields that means prefabs whose ROOT carries the component. Picking an asset
stores a persistent `{guid, fileID}` reference.

### Tabs per field type

Each drawer shows only the tabs its type can assign (hidden, not disabled):

| Field type   | Scene tab    | Project tab                                        |
|--------------|--------------|----------------------------------------------------|
| `Ref_Local`  | live objects | hidden (a local_id cannot reference another file)  |
| `Asset_GUID` | hidden       | assets; `ref:"Type"` tag filters to scene assets whose root has that component; `ext:"glb,gltf"` tag filters by file extension (also gates drag-drop) |
| `Ref` (PPtr) | live objects | scene-asset roots; assigns the PPtr `{guid, root local_id}`; `pick:` tag can limit to one tab |

The "unlike Unity" part: `Asset_GUID` is a plain guid, yet with a `ref:"Type"`
tag the Project tab still filters by root component — e.g.
`projectile_prefab: Asset_GUID ref:"Projectile"` lists only prefabs that are
actually projectiles. The guid is what game code wants for instantiation, so
no new reference machinery is needed for this to be useful.

### Field row layout (Unity-like)

```
Label   [ value          ] [x] [pick]
```

- **Label**: plain field name.
- **Value button**: shows the referenced object's name / "None".
  - Single click PINGS: reveal + fading highlight (~0.5s), selection
    untouched — in the hierarchy for scene objects, in the project view for
    assets.
  - Double click acts: SELECTS the scene object in the hierarchy / OPENS the
    asset (selected in the project view; scene loads, .asset goes to the
    inspector).
- **[x] remove**: shown only when the value is not None, placed BEFORE the
  picker button.
- **[pick]**: opens the picker popup (drag-drop onto the value stays
  supported).

### AssetDB indexes

The Project tab must answer "which scene assets have component X at their
root?" without parsing files on popup open. AssetDB already maps guid↔path;
it grows two more structures, built from each scene asset's root record:

```
Asset_Root_Info :: struct {
    root_local_id: Local_ID,
    root_name:     string,
}
root_info: map[Asset_GUID]Asset_Root_Info

// Inverted index — the picker's actual query. Values are complete PPtrs
// (asset guid + root component local_id), so a project pick IS the
// persistent pointer, same as Unity's guid+fileID. TypeKey is runtime-only
// (its numeric value shifts between builds), which is fine here: the index
// is rebuilt from the root component type GUIDs (via the component registry)
// on every refresh and never serialized.
assets_by_type: map[TypeKey][dynamic]PPtr
```

ROOT ONLY — caching whole hierarchies would turn the db into a second scene
format. Deep objects are picked in the scene after instantiating, same as
Unity.

### Refresh (no watcher, no polling)

`asset_db_refresh` diffs the tree's mtimes/sizes against a `file_state`
snapshot (Unity's SourceAssetDB idea) and processes only the deltas —
create / modify / delete, rename as delete+create with the guid riding the
moved meta. Triggers: the editor's own file operations (save, rename, create)
and window focus regain (Unity Auto Refresh) — external edits are picked up
when you return to the editor. Details in roadmap step 5.

## Non-goals

- Picking non-root objects of an unloaded asset (would need full-hierarchy
  indexing; open the asset instead).
- Live cross-asset handles for `Ref_Local` — upgrade the field to `Ref` when a
  component genuinely needs a cross-file reference.
