---
title: "Saving and discarding"
description: "Open documents, Save and Discard, the dirty star and the quit prompt"
order: 125
tags: ["save", "discard", "documents", "editor"]
path: editor/editing
---

# Saving and discarding

An open document is a file loaded for editing (`moonhug/editor/session/documents.odin`): loaded scenes and serialized assets. An owner is the code that holds loaded copies, not a file type. There are two: the scene manager's loaded scenes, and the inspector's asset documents, which cover every serialized asset type. Every view that edits an asset shares its one document: the Project Inspector, the Animation, Shader Graph and Render Pipeline windows. Each owner reports what it holds when asked, so no list is kept. A view names the document it shows, and its tab menu offers Save and Discard for it. File/Save saves every dirty document.

Import settings are not documents. They commit through Apply and go back through Revert ([Undo](Undo.md)).

- **Discard is final.** The document is read again from its file and its undo steps are purged (`undo.purge_asset`, `undo.purge_scene`).
- **After a save**, a hook per asset type refreshes what the file feeds (`inspector.doc_saved_register`): the Shader Graph reimports and drops its cached shader, the Render Pipeline reimports.
- **The star** goes before `###` in a window title. imgui keys the window and its dock place on the text after `###`, so the star never moves a tab.
- **Quitting** with dirty documents asks first, through one check (`quit_gate`, `editor/quit_prompt.odin`) that File/Quit, the window's close button and Relaunch all pass. During a Relaunch, `mh` waits while the editor runs and the ready marker exists. Cancel removes the marker, so nothing launches.

## A window that edits an asset

The window keeps the asset's guid and edits its shared document (`inspector.asset_doc_get`), allocating with `inspector.doc_alloc()`. It never keeps the document pointer across frames: an undo, a redo or a Discard replaces the instance. It names the document from a `@(provider_install)` proc:

```odin
@(provider_install)
_install :: proc() {
	session.view_document_set("my_window", _view_document) // the id after ### in the title
}
```

An editor that needs its own working copy, applied to the asset at once, registers its own owner instead (`session.document_owner_add`): `list` reports the copy, `save` applies it, `discard` drops it. Plugin windows get the star on their tab from the window registry.
