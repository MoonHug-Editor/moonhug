# Nested Prefabs WIP Plan

> MoonHug Editor uses scenes as prefabs so prefab is synonym to scene in thid document.

## Links
- [Technical deep dive into the new Prefab system - Unite LA](https://www.youtube.com/watch?v=HxbSJ-EIjXI)
- [Understanding Unity’s serialization language, YAML](https://unity.com/blog/engine-platform/understanding-unitys-serialization-language-yaml)

## Roadmap

- nested prefabs roadmap:
  - [v] scene tree data model
  - [v] serialization: scene tree file with guid in project
  - [v] asset registry: AssetDB
  - [v] instantiate scene tree as child

  - [v] prefab instance record
  - [v] transparent nested scene
  - [v] prefab overrides: nested scene instance overrides

  - [v] deep nested prefabs
  - [v] breadcrumbs — stripped-placeholder anchors for `Ref_Local` and NS hosts

  - prefab variants

# Design

## Scene File Format

Following Unity's approach, `NestedScene` is **metadata** in the scene file — not a component on a transform. The transform tree only contains non-nested-owned nodes.

```
SceneFile {
  root:              Local_ID
  next_local_id:     Local_ID
  transforms:        []Transform         // only non-nested-owned nodes
  nested_scenes:     []NestedScene       // metadata, analogous to Unity PrefabInstance
  breadcrumbs:       []Breadcrumb        // stripped-placeholder anchors for intra-file
                                         // refs into nested-owned content (NS hosts,
                                         // Ref_Local picker into nested subtree)
  ...components...
}
```

### NestedScene record (metadata)

Analogous to Unity's `PrefabInstance` YAML object:

```
NestedScene {
  local_id:           Local_ID     // file ID of this record (in this scene's namespace)
  local_id_in_parent: Local_ID     // file-stable lid in the parent prefab; equals
                                   // `local_id` for native NSs. Used as the XOR
                                   // projection key — same-prefab-instantiated-twice
                                   // produces distinct keys per outer instance.
  source_prefab:      Asset_GUID   // GUID of the nested scene asset (m_SourcePrefab)
  transform_parent:   Local_ID     // local_id of the parent transform (m_TransformParent)
  host_breadcrumb_id: Local_ID     // breadcrumb peg standing in for the host transform,
                                   // so other rows in this file can Ref it by local_id
  sibling_index:      int          // order among siblings
  overrides:          []Override   // property overrides
}
```

`transform_parent == 0` means root — this is how Prefab Variants work in Unity (the base prefab is a `NestedScene` with no parent).

### Override record

Analogous to Unity's `m_Modifications[i]`. Each override is a modification recorded at the root scene level only.
  - The currently open scene file owns all overrides it applies to its nested instances.
  - Inner prefab files own their own overrides on their direct children. Those are *opaque* to the parent — the parent sees the inner instance with its own overrides already baked in.
  - At runtime each level applies its own overrides to its own direct child during bake. The root's overrides on something deep in the chain are then patched onto the live tree post-resolve (`cleanup_T` + `unmarshal_any` on the located field).

```
Override {
  target:        PPtr       // (deepest_prefab_guid, projected_lid) — names the row
                            // directly. The owning NestedScene supplies the implicit
                            // scene_instance.
  property_path: string     // dot-separated path e.g. "position.x", "color"
  value:         json.Value // override value
}
```

`target` semantics — matches Unity's `target: {fileID, guid}`:
- **Shallow** (the row lives directly in `ns.source_prefab`): `target.guid == ns.source_prefab` and `target.local_id` is the row's lid in that prefab. No projection.
- **Deep** (the row lives N levels below `ns.source_prefab`): `target.guid` names the deepest prefab; `target.local_id` is the leaf-prefab-namespace lid XOR-projected through every inner NS's `local_id_in_parent` on the way up. Resolution at load is a DFS over runtime NSs descending from the owning native NS, un-projecting one key per level until a candidate NS with `source_prefab == target.guid` resolves the lid in its own subtree. Same-prefab-instantiated-twice along one chain disambiguates because each instance's `local_id_in_parent` differs.

Rules:
- Entire array is one atomic override. Never override individual elements. If anything inside the array changes, the whole array is the override value.

### Breadcrumb record

Analogous to Unity's stripped Transform objects (marked with `stripped` tag): a placeholder row in this file that stands in for an object living inside a nested prefab so other rows in the same file can reference it by `local_id`. **Not used for override targets** — those carry their own `(guid, projected_lid)` on `Override.target`.

Used for:
- `NestedScene.host_breadcrumb_id` — the host transform peg, so a `parent` field or a `children` ref can point at the NS host.
- `Ref_Local` fields picking an object inside a nested subtree — the picker creates a breadcrumb so the field can store a single `local_id` that survives serialization.

```
Breadcrumb {
  local_id:       Local_ID   // local_id referrers in this file use to refer to the target
  scene_source:   PPtr       // (deepest prefab guid, XOR-projected lid) — same encoding
                             // as Override.target
  scene_instance: Local_ID   // anchor: native NS local_id in this file
}
```

Resolution at load loads the target if needed, wires the real object handle into `Scene.local_ids[local_id]`, and the breadcrumb stays in the file (for the next save round-trip) but is invisible to the live scene.


## Runtime usage

- bake and diff operations work on Json Value trees for genericness and simplicity

### Instantiating a NestedScene at runtime
- Load source prefab asset by `source_prefab` GUID
- Bake `overrides` on top before deserialization
- Instantiate it as a child of the transform identified by `transform_parent`

### Instantiating a variant prefab
- Bake(Unpack) root and overrides into a single json as if there were no overrides at all
- Cache and use baked JSON to instantiate variant prefab

## Edit time usage

`NestedScene` records live in `SceneFile.nested_scenes`. They are not present in the runtime transform tree directly — at edit time the editor resolves them into live transform nodes (nested_owned), and on save collapses them back to metadata records.

### Overrides

- A scene file's `NestedScene` record holds overrides on its **direct** child prefab only — items in that child's prefab namespace.
- Overrides targeting items deeper in the chain (e.g. root → A → B → leaf inside B) are still owned by the root scene's `NestedScene`. `target.guid` names the deepest prefab the field lives in, and `target.local_id` is the leaf-prefab lid XOR-projected through every inner NS's `local_id_in_parent` on the way up. Inner `NestedScene` records never store the root's overrides.
- Inner `NestedScene` records loaded into memory at runtime carry their own prefab file's overrides (e.g. A.scene's overrides on B). Those exist as runtime state to drive each level's own-overrides bake during resolve, and are never persisted by the open scene's save.

Serialization triggers baking base and working copy, diffs them to produce overrides written onto the **root** scene's `NestedScene` record.
- UX: overrides grow only — if same value but override exists, keep it
- Removing an override requires explicit UI action (revert)
- diff produces overrides between baked_base and working_copy
- baked_base for a chain depth N walks all N prefab files in order, applying each file's NS-for-next-child overrides to the next prefab's raw — this is the "what this nested instance looks like before any root-scene overrides" baseline

### Enter prefab (planned UX, not yet implemented)

Enter prefab N:
- baked_base    = bake(chain[0..N-1])
- working_copy  = bake(chain[0..N]) <- user sees and edits this

#### Examples
Enter prefab 0(root):
- baked_base    = bake(chain[0..-1]) <- nothing
- working_copy  = bake(chain[0..0]) <- bakes root(self)

Enter prefab 1(root+variant):
- baked_base    = bake(chain[0..0]) <- baked root
- working_copy  = bake(chain[0..1]) <- bakes root + variant


### Exit prefab (planned UX, not yet implemented)
- Save/Discard/Cancel

### Changes propagation
On save, for the saved prefab's GUID:
- Refresh `scene_lib`'s cached bytes for that GUID with the freshly-written file.
- Invalidate the runtime unpacked-snapshot cache (so subsequent runtime instantiations re-bake from the new content).
- Walk every loaded scene; for any chain that transitively contains the saved GUID (the saved prefab itself OR any inner NS whose `source_prefab` matches), find the native NS at the top of that chain and re-resolve it. The re-resolve rebuilds the subtree fresh with the new prefab content while preserving the open scene's overrides.

## Extras
- Apply override — writes override back up the chain to the source asset, removes it from the `NestedScene` record.
- todo (not yet implemented)

Revert override — discards a specific override on the `NestedScene` record, restoring the field to the value it would have without that override.
- Removes the matching `(target, property_path)` entry from the root NS's overrides.
- Recomputes the baseline by re-baking the prefab chain WITHOUT the entry being reverted (peer overrides on the same NS still apply). For depth ≥ 2 this composes every level's prefab file overrides correctly, not just the immediate outer.
- Locates the live field via reflection over the materialized subtree, calls `cleanup_T` on it, then `json.unmarshal_any` writes the recomputed baseline value into the slot.

### Stale-reference cleanup divergence from Unity

Unity intentionally preserves orphan modifications and stripped objects so that re-adding a removed script field or asset can recover the reference. This codebase is more aggressive: save drops overrides whose `target.local_id` no longer exists in the prefab named by `target.guid`, and prunes orphan stripped-placeholder breadcrumbs that no NS host or live `Ref_Local` references. Trade-off: cleaner files, no recovery on accidental field removal.

# Consider Later
## Scene edit stack
- enter inner prefab pushes to scene edit stack
- exit inner prefab pops from scene edit stack

## Prefab isolation mode
- show fully colored prefab in grayed out context
