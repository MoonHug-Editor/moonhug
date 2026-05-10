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
  - [v] breadcrumbs — serialized nested-cross-scene references

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
  breadcrumbs:       []Breadcrumb        // placeholder anchors for cross-scene refs
  ...components...
}
```

### NestedScene record (metadata)

Analogous to Unity's `PrefabInstance` YAML object:

```
NestedScene {
  local_id:         Local_ID       // file ID of this record
  source_prefab:    Asset_GUID     // GUID of the nested scene asset (m_SourcePrefab)
  transform_parent: Local_ID       // local_id of the parent transform in this file (m_TransformParent)
  sibling_index:    int            // order among siblings
  overrides:        []Override     // property overrides
}
```

`transform_parent == 0` means root — this is how Prefab Variants work in Unity (the base prefab is a `NestedScene` with no parent).

### Breadcrumb record (Analogous to Unity's stripped Transform objects (marked with `stripped` tag))
Breadcrumb  is the serialized form of a cross-scene Handle reference.
  - created in scene file for cross-scene references - different referrer source_prefab vs reference source_prefab.
  - resolved back into a Handle on load.
  - enough data to load the real object **once**, after resolve breadcrumb is dropped and referrers hold a normal local id / handle.


Rules:
- Referencing in file should use local_id only
- When local_id doesn't exist it should be created
- During serialiation cross-scene references are converted into breadcrumbs

```
Breadcrumb {
  local_id:              Local_ID   // local_id referrers will use to refer this element
  scene_source:          PPtr       // asset guid + local_id in that asset of this element
  scene_instance:        Local_ID   // scene instance local_id in this file
}
```

Live scene (post-deserialize):
- Persisted breadcrumbs live only in `SceneFile`
- `Scene.local_ids` maps entity `local_id`s to real pool handles (transforms, components, etc.).
- Resolving a cross-scene reference loads the target if needed, wires the real object, then removes the breadcrumb.

### Override record
Override is a modification recorded at the root scene level only.
  - The currently open scene file owns all overrides it applies to its nested instances.
  - Inner prefab files own their own overrides on their direct children. Those are *opaque* to the parent — the parent sees the inner instance with its own overrides already baked in.
  - At runtime each level applies its own overrides to its own direct child during bake. The root's overrides on something deep in the chain are then patched onto the live tree post-resolve (`cleanup_T` + `unmarshal_any` on the located field).

```
Override {
  target:        Local_ID   // either: local ID of an Transform/Component inside this same prefab,
                            // OR a breadcrumb local_id (for deep overrides — the
                            // breadcrumb's scene_path encodes the chain to the
                            // real destination)
  property_path: string     // dot-separated path e.g. "position.x", "color"
  value:         json.Value // override value
}
```

- Entire array is one atomic override. Never override individual elements. If anything inside the array changes, the whole array is the override value.


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
- Overrides targeting items deeper in the chain (e.g. root → A → B → leaf inside B) are still owned by the root scene's `NestedScene`, but the `target` is a breadcrumb whose `scene_path` traverses the chain. Inner `NestedScene` records never store the root's overrides.
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

Unity intentionally preserves orphan modifications and stripped objects so that re-adding a removed script field or asset can recover the reference. This codebase is more aggressive: save drops overrides whose `target` no longer exists in the current prefab raw, and prunes orphan deep-override anchors that no override or NS host references. Trade-off: cleaner files, no recovery on accidental field removal.

# Consider Later
## Scene edit stack
- enter inner prefab pushes to scene edit stack
- exit inner prefab pops from scene edit stack

## Prefab isolation mode
- show fully colored prefab in grayed out context
