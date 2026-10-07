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

`docs/reference/` is generated and gitignored, and written by `mh docs` only. The prebuild checks attributes, field tags and naming conventions on every build, and writes their pages when `mh docs` runs it with `--docs`. The four parts:

- `attributes/<layer>/`, one folder per layer (`host`, `editor`, then each plugin by name) with one page per attribute, written by `moonhug/prebuild/attributes_gen`.
- `field_tags/<layer>/`, the same layout with one page per field tag key, written by `moonhug/prebuild/field_tags_gen`.
- `naming/<layer>/`, the same layout with one page per naming convention, written by `moonhug/prebuild/naming_gen`.
- `packages/<layer>/`, the same layout with one page per package of the host, the editor and every installed plugin, written by `mh docs` (`tools/mh/package_docs.odin`). `mh docs` writes an entry file that imports every package, runs `odin doc -doc-format` on it once, and reads the binary `.odin-doc` file Odin writes (`core:odin/doc-format`), the way pkg.odin-lang.org documents Odin's own libraries. Each page lists the package's public declarations by kind, with signatures whose types link to the declaring package's page, attributes linked to their reference pages, the doc comment and `file:line`. `_name` and `@(private)` declarations are left out. A signature longer than one line puts its parameters one per line. In a doc comment, a `name` in backticks links to the declaration when it names one of the package's own, `pkg.Name` of a documented package, or `@(attribute)`, so writing names in backticks is what makes them links. A named proc type lists every procedure with its signature, and a struct does the same for each field written as a `proc(...)`, such as the fields of a provider. A signature that takes and returns nothing gets no list. An extension point links to its attribute's page.

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

An attribute nothing uses is a warning. `@(reserved)` on a declaration says it is kept on purpose while nothing uses it yet, as `@(before_serialize)` is kept for plugins, and the prebuild skips the unused warning for it. It works the same on an attribute's declaration, a field tag constant and a proc of a naming convention, and never turns off an error.

## Field tags

A struct field's tag tells the inspector how to draw the field and what it accepts: `ref:"Transform"`, `ext:"mat" expand`, `decor:min(0)`. Field tags are not attributes. Each key is declared as a value, a `Field_Tag` constant in the package that reads it, and the declaration is what its reference page is made from:

```odin
// Limits an Asset_GUID field to files with the given extensions.
//
// A comma list without dots: `ext:"glb,gltf"`. ...
TAG_EXT :: Field_Tag{key = "ext", form = .Value}
```

- The doc comment is the key's explanation, and its first sentence is the summary on the index.
- `form` is how the key is written: `.Value` is `key:"text"`, `.Flag` is a bare `key` (`key:""` reads the same), `.Call` is `key:name(args)`, and only a Call key may appear several times in one tag, as `decor` does.
- The package the constant sits in decides its layer on the index: `host`, `editor`, then each plugin by name.

The `decor` page also lists every decorator, each a `decorator_<name>` proc in `moonhug:editor/inspector`, with its parameters and its number of uses.

`Field_Tag`, `Field_Tag_Form`, the editor's own keys and the readers are in `moonhug/editor/inspector/field_tags.odin`. Code reads a key through its constant rather than a string literal:

- `tag_value(tag, TAG_EXT)` returns a Value key's text, or a Call key's first call as written (`min(0.5)`), and whether the tag carries the key.
- `tag_has(tag, TAG_EXPAND)` says whether the tag carries the key, in any spelling its form accepts.

A plugin declares its own keys the same way, in its `editor/` part, which imports `moonhug:editor/inspector`, and reads them with the same procs:

```odin
import "moonhug:editor/inspector"

// Draws the field as a layer mask, with one toggle per layer the project names.
TAG_LAYERS :: inspector.Field_Tag{key = "layers", form = .Flag}
```

Value keys come first in a tag. Odin's `reflect.struct_tag_lookup`, which `tag_value` and `core:encoding/json` both use, stops reading at the first bare word, call or line break.

The prebuild checks every struct field tag in the scanned code against the declarations and stops on:

- a key no declaration names, with the nearest declared key as a suggestion
- a key written in another form than its declaration's, as `expand:"x"` or a bare `ref`
- a Value key after a bare word, a call or a line break, where it is never read
- a Value or Flag key that appears twice in one tag
- a tag it cannot split into keys, as an unclosed quote or parenthesis
- a key declared twice, a declaration without `key`, and a `form` that is not `.Value`, `.Flag` or `.Call`

A declared key no field uses is a warning, unless its constant carries `@(reserved)`, as `TAG_PICK` does. Generated files and test packages are not checked. Without the check a misspelled `exapnd` compiles and silently does nothing, so a new key needs its `Field_Tag` constant in the same change.

## Naming

Some procs are called because of their name. `cleanup_Camera` runs because type_guid_gen looks for `cleanup_<T>` in the file of every `@(typ_guid)` type, `decorator_min` because a field says `decor:min(...)`, `apply_Value_Command` because the undo command dispatch calls it. Naming conventions are neither attributes nor field tags. Each belongs to the generator that resolves it, which declares it at `@(init)` and records its subjects in its provide step:

```odin
gen_facts.register_naming({
	key     = "clip_tween",
	title   = "Clip tween procs",
	subject = "a type embedding `base: Clip_Tween`",
	layer   = "sequencer",
	owner   = "tween_gen",
	scope   = .Subject_File,
	procs   = {
		{prefix = "evaluate_", signature = "proc(v: ^T, t: f32, ctx: ^core.Tween_Ctx)", summary = "Poses the target at clip-normalized time t."},
	},
	doc     = "...",
})

// In provide, for every variant found:
gen_facts.naming_subject("clip_tween", decl.name, decl.file_path, where_)
```

- `procs` lists the names the convention resolves, `<prefix><Subject>`, with their signature and whether every subject must have one.
- `scope` is where the owner looks: `.Subject_File` (the file that declares the subject), `.Package` (one package, `package_path`) or `.Any`.
- `unclaimed` decides what a proc with the prefix and no subject behind it is: `.Near_Miss` (the default, an error only when it is a typo of a subject), `.Warn` or `.Error` for a convention that owns its prefix, as `decorator_` and `mcp_tool_` do.
- `layer` places the convention on the index: `host`, `editor`, or the plugin whose `gen/` declares it.

The types and the registry are in `moonhug/prebuild/gen_facts/naming.odin`. The prebuild stops on:

- a proc that names a subject but is not where the owner looks, so it is never called: `on_validate_Camera` in another file than `Camera`
- a proc that is a near miss of a subject, with the subject as a suggestion: `cleanup_Camra`
- for a convention with `unclaimed = .Error`, a proc with its prefix that is not one of its subjects: `mcp_tool_probe` without `@(mcp_tool)`

With `unclaimed = .Warn` such a proc is a warning instead, as an unused decorator is, unless the proc carries `@(reserved)`. Missing required procs are the owner's error, since the owner knows what it cannot generate without them. A generator that finds code by name declares its convention in the same change.
