---
title: "Documentation"
description: "How the documentation site is assembled from the repo's markdown, generated reference pages and the README"
weight: 15
tags: ["build", "contributing", "prebuild"]
---

`mh docs` (or `make docs`) builds the site into `builds/docs`, clearing that folder first. Double-click `builds/docs/index.html` to read it from the file system. `mh docs --open` (or `make docs OPEN=1`, since make cannot pass `--open` through) serves it with `hugo server` on port 7272, rendering to memory so the server never writes into `builds/docs` (`DOCS_PORT` in `tools/mh/docs.odin`) and opens the browser, which is the mode where search works.

## What is here

- `hugo.toml` is the site config. Every path in it is relative to the repo root, because `mh docs` runs Hugo with `--source .`.
- `themes/hextra` is the theme, a git submodule. A fresh clone needs `git submodule update --init`.
- `layouts/_markup/render-link.html` is the theme's link hook with one addition: it translates repo paths into site paths, see Links below.
- `layouts/_partials/custom/head-end.html` fills one of the theme's empty hook partials: it lifts the article column's fixed 72rem cap, so with `params.page.width = 'full'` in the config every page uses the whole window. No theme file is copied.

## How the content is assembled

The site follows the repo one level down: `docs/general` is `/general`, `docs/core` is `/core`, `docs/reference` is `/reference`, each `plugins/<name>/docs/` is `/plugins/<name>`, and the README is the home page. The navbar search box is a `[[menu.main]]` entry with `params.type = 'search'`, which is the only way the theme renders one. `mh docs` writes every Hugo mount into `builds/docs-mounts.toml`, because a later config file replaces an earlier one's mounts array rather than adding to it, so they all have to come from one place.

`mh docs` also writes `builds/docs-home/`, every page that exists only on the site: a copy of the README with frontmatter (an empty title, since the README has its own heading and the theme prints the title as one), the notices file it links, the Plugins section index, and a landing page per plugin titled from `mh_plugin.json`. Nothing hand-written lives outside `docs/` and the plugins' `docs/` folders. The README's links are repo paths like every page's, and the link hook resolves them.

## Links

Links are relative paths in the repo, so they work on GitHub and on the site alike: `[Undo](Undo.md)` within a section, `[Concepts](../general/Concepts.md)` across sections.

A plugin page linking into `docs/` starts the path at the repo root instead, since its relative path would climb three levels: `[Undo](/docs/core/Undo.md)`. GitHub reads a leading `/` as the repository root.

On the site, `layouts/_markup/render-link.html` maps a repo path to the site path before looking the page up: `docs/<section>/` loses its `docs/` prefix, `plugins/<name>/docs/` loses its `docs/` folder, and `README.md` is the home page. A link it cannot resolve stays a `.md` link, which is how a broken one shows up.

## Reading from the file system

Two things stand between a Hugo theme and a double-clicked `index.html`:

- Subresource integrity. Themes put `integrity="…"` on their stylesheets and scripts. Browsers verify it through CORS, and a `file://` page has no origin to pass that with, so the resources are refused and the page opens unstyled. `mh docs` strips `integrity` and `crossorigin` from every built page after the build. The attributes guard against a tampered CDN, which a local file read does not have.
- Search. Every theme loads its index with `fetch()`, which browsers refuse on a `file://` page. Patching a theme's search script works but has to be redone for each theme, so it is not done. `mh docs --open` serves the site over http, where search works untouched.

## Generated pages

`docs/reference/` is generated and gitignored, in two parts: `attributes/<layer>/`, one folder per layer (`host`, `editor`, then each plugin by name) with one page per attribute, written on every build by `moonhug/prebuild/attributes_gen`, and `packages/`, one `odin doc` page per engine and editor package written by `mh docs` (`tools/mh/docs.odin`).

## Attributes

Attributes are how code extends the engine and the editor, so each one is declared, and the declaration is what its reference page is made from. The declaration sits on the declaration that receives the attribute's registrations, in the package the attribute extends:

```odin
// Adds a widget to the editor toolbar, in its left, center or right zone.
//
// `zone` is "left", "center" or "right", and `order` sorts items inside a zone. ...
@(extension_point={attribute="toolbar", target="proc", fields="zone order"})
toolbar_add_item :: proc(zone: Toolbar_Zone, draw: proc(), order := 0, origin := "") {
```

- The doc comment is the attribute's explanation, and its first sentence is the summary on the index.
- The package the declaration sits in is the package the attribute extends. The index groups attributes by layer, Host, Editor, then each plugin by name, and by that package inside a layer.
- `fields` lists the keys the attribute takes. A trailing `*` matches by prefix, as in `param_*`.
- `target` says what the attribute goes on (`proc`, `var`, `type`). It is documentation only.

The prebuild checks every attribute in the scanned code against these declarations and stops on an attribute that is neither Odin's nor declared, or on a field its declaration does not list. The build passes `-ignore-unknown-attributes`, so without this check a misspelled `@(menu_iten)` or `ordr=` compiles and silently does nothing. A new attribute, from the engine or from a plugin's `gen/`, needs its `@(extension_point)` in the same change.
