---
title: "Sub-assets and Embedded Assets"
description: "Where an asset can live: in a file of its own, inside another file as a sub-asset, or inside the one field that uses it"
weight: 85
tags: ["assets", "scenes", "editor"]
path: editor
---

An asset such as a material or a noise map can live in three places. Where it lives decides who can use it and whether the project gets one more file.

| | File | Sub-asset | Embedded asset |
|---|---|---|---|
| Where its data is | its own file, `Marble.mat` | inside another file, a scene file's `assets` list | inside the one field that uses it |
| Who can use it | any field | any field | only that field |
| The Project window | lists it | lists it under its file | does not list it |
| A copy of the object | points at the same file | points at the same sub-asset | gets a copy of its own |
| The picker shows it as | `Marble` | `demo / Marble` | `Material (embedded)` |

- Use a **file** for an asset many scenes share.
- Use a **sub-asset** for an asset that belongs with a scene: several objects of that scene can share it, and it moves, copies and ships with the scene.
- Use an **embedded asset** for an asset only one field needs. The project gets no extra file and nothing to name.

A model's meshes, parts and clips and a texture's sprite slices are sub-assets too. Their importer makes them, so they are read-only (see [Sub-asset files](AssetPipeline.md#sub-asset-files)). The sub-assets this page is about are the ones you make, stored in scene files.

## Making one

A reference field's picker has rows that give the field an asset of its own. Each row says what it makes and where it lives:

- **New <Type> (sub-asset)**: a new asset with the type's defaults, added to the file the field belongs to. That is the scene of the inspected object, or the file of the inspected sub-asset.
- **Copy (sub-asset)**: a copy of the asset the field points at, a file or a sub-asset, unsaved edits included, added to the same file.
- **New <Type> (embedded)** and **Copy (embedded)**: the same, written inside the field.

There is one New row per asset type the field takes that Assets > Create can make. An empty field has only the New rows. A type whose files go through an importer, such as Animation and Shader Graph, has no New or Copy rows: it loads from the importer's output, which an asset stored inside another file does not have.

Other ways to make a sub-asset:

- Assets > Create with a sub-asset selected makes the new asset inside that sub-asset's file. For a type whose files go through an importer it makes a file.
- Edit > Duplicate with a sub-asset selected copies it inside its file.
- Assets > Duplicate as Asset copies a selected sub-asset into a file of its own beside its file. It is a plain copy: its references to the file's other sub-assets keep pointing at them.

## Editing

**A sub-asset** is selected and edited like a file: click its row under its file in the Project window, and the Project Inspector shows it. A double click on a reference to it selects it too.

- While its scene is open, an edit is an edit of that scene. The scene shows as edited, Save writes it, and Undo takes it back.
- While its scene is not open, the edit is held like an edit of a file, and Save writes it into the scene file. If the scene opens before that, the scene takes the edit.
- Rename and Delete in the Assets menu act on a selected sub-asset. Delete asks first, as it does for a file. In an open scene both are undo steps. In a scene that is not open they change the file on disk, with no undo.

**An embedded asset** is edited in the foldout under its field. The arrow is always there for an embedded asset. An edit is an edit of what holds the field:

- a component's field: the object's scene shows as edited, also when another scene is the active one
- a field of an asset, such as a material's texture: the asset shows as edited, and its Save writes the change
- a settings field: the settings save it as they save any change

Undo and redo keep the field's embedded asset, and so does Play then Stop: an edit made before Play can still be undone after Stop.

## Prefabs and variants

- A prefab's sub-assets stay in the prefab's file. Every instance points at the same sub-asset, so an edit of it reaches every instance.
- A variant, opened or nested, uses its base's sub-assets the same way.
- An override, in a scene that holds an instance or in a variant, can point at that scene's own sub-assets or hold an embedded asset. A scene that nests the variant gets the override.
- Each instance of a prefab that holds an embedded asset has its own copy of it, read from the prefab's file.

## In the file

A scene file lists its sub-assets under `assets`. Each record has a local id, a type spelled like a file extension, an optional name, and the data the asset's own file would hold:

```json
"assets": [
  {"local_id": 77, "type": "mat", "name": "Marble", "data": {"color": [0, 1, 0, 1]}}
]
```

A reference is a `PPtr`, a file's guid and a local id:

- a whole file: its guid, `"6f1e...c2"`
- a sub-asset of another file: `{"local_id": 77, "guid": "<that file's guid>"}`
- a sub-asset of the same file: `{"local_id": 77, "guid": "00000000-0000-0000-0000-000000000000"}`. The empty guid means "this file", so a copy of the file points at its own records
- an embedded asset: `{"embedded": "mat", "data": {"color": [0, 0, 1, 1]}}`, where the reference would be

## At runtime and in an export

- A loader reads an asset through its key, `asset_key(ref)`, and `asset_source(key)` gives it the data of a file or of a record. Material and Noise Map load this way. A type with an importer loads from the importer's artifact instead, which is why it cannot live inside another file.
- An export needs nothing extra. A sub-asset ships with its scene file, and the export ships a scene file that something references. An embedded asset is part of the file that holds its field.

## Limits

- Only types with no importer can be sub-assets or embedded assets (`subassets.can_live_inside`). Their loader must also read through `asset_source`, as Material and Noise Map do.
- Settings and component fields of type `Asset_GUID` with a `ref:` tag (physics layers and materials, the render pipeline, render layers, group names, input actions) point at files only. Only `PPtr` fields have the sub-asset and embedded rows.
- References inside an embedded asset's data name files by their full guid, a sub-asset of the same scene included.
- An embedded asset is never shared or merged with an equal one. Each field holds its own.

## How it works

- A scene's records live on the open scene (`Scene.assets`, written by its save) and in a table that references resolve against: an open scene's records as they are now, and any other scene file's records, read from its bytes on first use (`plugins/engine/scene_sub_assets.odin`).
- A reference into the file being read gets that file's guid when it is read, and loses it when the scene is written. While a nested prefab is read, "this file" is the prefab's file, then its bases when it is a variant, then the host scene.
- In memory an embedded field holds `PPtr{core.EMBEDDED_ASSETS, id}` with a session id, and its data is a record in the same table. So loaders, documents and the foldout work for it as for a sub-asset. Records live until the editor or game exits.
- The inspector remembers what holds each embedded asset, from where it is made and where its foldout is drawn (`inspector.embedded_holder_set`). An edit marks that holder edited, not the active scene.
- An undo snapshot and the Play snapshot write an embedded asset with its id (`serialization.pptr_embedded_ids`), so reading the snapshot back gives the field the same embedded asset. A file, a copy and a multi-edit never write the id, so two fields never share one.
- `no_embed = true` in an asset type's `menu_assets_create` keeps the embedded rows off every field for that type.
- The Project window rows, the picker rows and the documents come from a provider per file type: see [Plugins](Plugins.md), sub-asset providers. The scene file's provider is `plugins/engine/editor/drawers/scene_sub_assets.odin`.
