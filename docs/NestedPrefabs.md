# Nested Prefabs WIP Plan

- nested prefabs roadmap:
  - [v] scene tree data model
  - [v] serialization: scene tree file with guid in project
  - [v] asset registry: AssetDB
  - [v] instantiate scene tree as child

  - prefab instance node type:
    - [v] opaque nested scene, instantiated at gameplay only
    - [wip] transparent nested scene (metadata for ref and overrides)

  - property overrides: nested scene instance overrides
  - prefab variants
  

# Design
> MoonHug Editor uses scenes as prefabs so prefab is synonym to scene here.

## Scene File Format

Following Unity's approach, `Prefab_Instance` is **metadata** in the scene file — not a component on a transform. The transform tree only contains non-nested-owned nodes.

```
SceneFile {
  root:              Local_ID
  next_local_id:     Local_ID
  transforms:        []Transform         // only non-nested-owned nodes
  nested_scenes:     []NestedScene        // metadata, analogous to Unity PrefabInstance
  stripped_refs:     []Stripped_Ref      // placeholder anchors for cross-boundary refs
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

### Stripped_Ref record

A lightweight placeholder that appears in the outer file when something needs to reference an object inside a nested prefab:

```
Stripped_Ref {
  local_id:                   Local_ID   // file ID in this file
  corresponding_source_object: Local_ID  // file ID of the object inside the source prefab
  source_prefab_instance:     Local_ID   // local_id of the Prefab_Instance record
}
```

Analogous to Unity's stripped Transform objects (marked with `stripped` tag).

### Override record

```
Override {
  target:        Local_ID   // file ID of the component/transform inside the source prefab
  property_path: string     // dot-separated path e.g. "position.x", "color"
  value:         json.Value // override value
}
```

## Runtime usage

- bake and diff operations work on Json Value trees for genericness and simplicity

### Instantiating a Prefab_Instance at runtime
- Load source prefab asset by `source_prefab` GUID
- Bake `overrides` on top before deserialization
- Instantiate it as a child of the transform identified by `transform_parent`

### Instantiating a variant prefab
- Bake(Unpack) root and overrides into a single json as if there were no overrides at all
- Cache and use baked JSON to instantiate variant prefab

## Edit time usage

`NestedScene` records live in `SceneFile.nested_scenes`. They are not present in the runtime transform tree directly — at edit time the editor resolves them into live transform nodes (nested_owned), and on save collapses them back to metadata records.

### Overrides

- `NestedScene` holds `overrides` list for self and inner items, except for child `NestedScene`s
  - child `NestedScene`s behave the same way

Serialization triggers baking base and working copy, diffs them to produce overrides written back to the `NestedScene` record.
- UX: overrides grow only — if same value but override exists, keep it
- Removing an override requires explicit UI action (revert)
- diff produces overrides between baked_base and working_copy

### Enter prefab

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


### Exit prefab
- Save/Discard/Cancel

### Changes propagation
Saving a prefab walks all live `NestedScene` records whose `source_prefab` GUID matches the saved asset and reloads them.

## Extras
- Apply override — writes override back up the chain to the source asset, removes it from the `NestedScene` record.  
- Revert override — discards a specific override on the `NestedScene` record, restoring the field to the baked base value

# Consider Later
## Scene edit stack
- enter inner prefab pushes to scene edit stack
- exit inner prefab pops from scene edit stack

## Prefab isolation mode
- show fully colored prefab in grayed out context

## Stripped Refs
- a lightweight anchor instead of duplicating nested data
  - required for correct cross-scene-boundary component references
  - needed when outer scene nodes reference objects inside a nested prefab
