---
title: "Saving and discarding"
description: "Open documents, Save and Discard, the dirty star and the quit prompt"
order: 125
tags: ["save", "discard", "documents", "editor"]
path: editor/editing
---

# Saving and discarding

An open document is a file loaded for editing (`moonhug/editor/session/documents.odin`): loaded scenes, serialized assets, and the files the Shader Graph and Render Pipeline windows show. An owner is the code that holds loaded copies, not a file type: the inspector's owner covers every serialized asset. Each owner reports what it holds when asked, so no list is kept. A view names the document it shows, and its tab menu offers Save and Discard for it. File/Save saves every dirty document.

Import settings are not documents. They commit through Apply and go back through Revert ([Undo](Undo.md)).

- **Discard is final.** The document is read again from its file and its undo steps are purged. Shader Graph and Render Pipeline undo steps name their asset, so `undo.purge_asset` reaches them.
- **The star** goes before `###` in a window title. imgui keys the window and its dock place on the text after `###`, so the star never moves a tab.
- **Quitting** with dirty documents asks first, through one check (`quit_gate`, `editor/quit_prompt.odin`) that File/Quit, the window's close button and Relaunch all pass. During a Relaunch, `mh` waits while the editor runs and the ready marker exists. Cancel removes the marker, so nothing launches.

## Adding a document kind

A plugin whose window edits a file registers an owner and names the window's document from a `@(provider_install)` proc:

```odin
@(provider_install)
_install_document :: proc() {
	session.document_owner_add({name = "my_window", list = _list, save = _save, discard = _discard})
	session.view_document_set("my_window", _view_document) // the id after ### in the title
}
```

`discard` reads the file again and purges the document's undo steps. Plugin windows get the star on their tab from the window registry.
