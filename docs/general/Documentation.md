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
- `layouts/_partials/custom/head-end.html` fills one of the theme's empty hook partials: it lifts the article column's fixed 72rem cap, so with `params.page.width = 'full'` in the config every page uses the whole window. No theme file is copied.

## How the content is assembled

The site follows the repo one level down: `docs/general` is `/general`, `docs/core` is `/core`, `docs/reference` is `/reference`, each `plugins/<name>/docs/` is `/plugins/<name>`, and the README is the home page. The navbar search box is a `[[menu.main]]` entry with `params.type = 'search'`, which is the only way the theme renders one. `mh docs` writes every Hugo mount into `builds/docs-mounts.toml`, because a later config file replaces an earlier one's mounts array rather than adding to it, so they all have to come from one place.

`mh docs` also writes `builds/docs-home/`, every page that exists only on the site: a copy of the README with frontmatter (an empty title, since the README has its own heading and the theme prints the title as one), the notices file it links, the Plugins section index, and a landing page per plugin titled from `mh_plugin.json`. Nothing hand-written lives outside `docs/` and the plugins' `docs/` folders. The README's links are repo paths and are rewritten to the site's: `docs/<section>/` loses the `docs/` prefix and `plugins/<name>/docs/` loses the `docs/` folder.

## Reading from the file system

Two things stand between a Hugo theme and a double-clicked `index.html`:

- Subresource integrity. Themes put `integrity="…"` on their stylesheets and scripts. Browsers verify it through CORS, and a `file://` page has no origin to pass that with, so the resources are refused and the page opens unstyled. `mh docs` strips `integrity` and `crossorigin` from every built page after the build. The attributes guard against a tampered CDN, which a local file read does not have.
- Search. Every theme loads its index with `fetch()`, which browsers refuse on a `file://` page. Patching a theme's search script works but has to be redone for each theme, so it is not done. `mh docs --open` serves the site over http, where search works untouched.

## Generated pages

`docs/reference/` is written on every build and gitignored: attribute pages by `moonhug/prebuild/docs_gen`, one `odin doc` page per engine and editor package by `mh docs` (`tools/mh/docs.odin`).
