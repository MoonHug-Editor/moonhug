# Prebuild Generator

The prebuild step (`moonhug/prebuild`) scans the Odin source for attribute markers
(`@component`, `@phase`, `@typ_guid`, `@menu_item`, …) and emits the `*_generated.odin`
files the engine/editor/app depend on. It runs once before a build:

```sh
odin run moonhug/prebuild     # invoked by run.sh before the editor build
```

## Architecture

A small in-memory database (`gen_db`) holds **one entity per declaration**. Modules attach
**components** (extracted facts) to those entities, then query component combinations to
build code. Producers and consumers are decoupled through a shared component registry — a
generator can read any component without importing the module that produced it.

```
packages[] ──► scan ─────► one Entity per declaration, carrying DeclInfo
                            (the AST is walked exactly once)
                  │
                  ├─ classify (gen_facts): turn each decl's AST into plain-data
                  │            components — Kind/Proc/Struct, plus Attrs_GenComp
                  │            (every @(...) flattened) and Fields_GenComp (struct fields)
                  │
   Provide  ──►  providers read those facts and tag entities with their own
                  │         components (Tween_GenComp, Menu_GenComp, …), keyed by type
   Generate ──►  generators query components, build source text, emit GeneratedFile
                  │
 PostProcess ──►  one writer flushes every GeneratedFile to disk
```

Stages run strictly in order: **every provider runs before any generator runs**, so a
generator always sees the full set of components.

The AST is touched in exactly one place. `gen_facts` walks each declaration once and
materializes what generators need — attributes, struct fields, kind — as plain-data
components. Every `*_gen` module then works against those components and **never imports
`core:odin/ast`**: no module re-parses or unwraps `^ast.*` itself.

### Packages

| Package      | Role                                                                    |
|--------------|-------------------------------------------------------------------------|
| `gen_db`     | The database: entities, the component registry, queries, the pipeline.  |
| `gen_core`   | The typed AST facade — the only place that speaks `core:odin/ast`. Turns declarations into plain data: `DeclAttrs` (→ `Attr_Args`), `StructFields` (→ `Struct_Field`), `RenderValue`, `EnumFieldNames`, plus `ParsePackage` / file helpers. |
| `gen_facts`  | Runs `gen_core` once per decl and stores the result as shared components: `Kind_GenComp`, `Proc_GenComp`, `Struct_GenComp`, `Attrs_GenComp`, `Fields_GenComp`. Every module reads these instead of re-walking the AST. |
| `*_gen`      | One module per output concern (`tween_gen`, `menu_gen`, …). Self-registering. None import `core:odin/ast`. |

## How a module is structured

A module is a package that registers a **provider** and a **generator** from an `@(init)`
proc, plus one or more public component types. Dropping in a new `*_gen` package and importing
it once in `prebuild.odin` is all that's needed — no harness edits.

```odin
package tween_gen

import db "../gen_db"
import "../gen_facts"

// A public component. Any generator may read it via db.get_comps(w, Tween_GenComp).
Tween_GenComp :: struct { has_tick, has_free: bool }

@(init)
_register :: proc "contextless" () {
    db.provider("tween/provide",   provide)   // Provide stage
    db.generator("tween/generate", generate)  // Generate stage
}

// Provide: tag the entities this module cares about. Note: no `core:odin/ast` —
// struct fields arrive as plain data via gen_facts.Fields_GenComp.
provide :: proc(w: ^db.World) -> bool {
    decls   := db.get_comps_DeclInfo()
    fields  := db.get_comps(w, gen_facts.Fields_GenComp)   // shared base fact: struct fields as data
    tweens  := db.get_or_create_comps(w, Tween_GenComp)    // provide into the registry

    m := db.all_of(db.r(decls), db.r(fields))
    defer db.matcher_destroy(&m)
    for entity in db.matched(w, &m) {
        decl := db.get(decls, entity)
        // recognise a tween struct: a `base: Tween` field — no AST unwrapping.
        is_tween := false
        for f in db.get(fields, entity).fields {
            if f.name == "base" && f.type == "Tween" { is_tween = true; break }
        }
        if !is_tween do continue
        db.set(tweens, entity, Tween_GenComp{ /* extracted facts */ })
    }
    return true
}

// Generate: query components and emit a file.
generate :: proc(w: ^db.World) -> bool {
    decls  := db.get_comps_DeclInfo()
    tweens := db.get_comps(w, Tween_GenComp)

    m := db.all_of(db.r(decls), db.r(tweens))
    defer db.matcher_destroy(&m)
    for entity in db.matched(w, &m) {
        decl  := db.get(decls, entity)
        tween := db.get(tweens, entity)
        // ...build source text...
    }
    db.emit(w, "moonhug/engine/tween_generated.odin", /* contents */)
    return true
}
```

## High-level API (`gen_db`)

### Pipeline registration — called from `@(init)`
```odin
pre_processor (name, run, order := 0)   // before scan
provider      (name, run, order := 0)   // Provide stage
generator     (name, run, order := 0)   // Generate stage
post_processor(name, run, order := 0)   // PostProcess stage
```
`order` controls placement within a stage (lower runs first, then by name); pass a
negative value to run before peers, e.g. a provider of shared facts others depend on.

### Shared component registry
```odin
get_or_create_comps(w, T) -> ^Comps(T)   // provider: create-or-get the comps of type T
get_comps          (w, T) -> ^Comps(T)   // any module: fetch the comps of type T (nil if never provided)
get_comps_DeclInfo()             -> ^Comps(DeclInfo)   // shortcut for the per-declaration facts
```

### Reading / writing a component on an entity
```odin
get(comps, entity) -> ^T     // read or write through the pointer
has(comps, entity) -> bool
set(comps, entity, value)    // attach (or overwrite) a component
```

### Querying entities
Build a **Matcher** (a reusable value), then evaluate it to a list of entities.
`r(comps)` is the short alias for `comps_ref(comps)` — it names one store in the query.
```odin
all_of(r(first), r(second), …) -> Matcher   // start: entities present in ALL these stores
none_of(&m, r(excluded), …)                 // add exclusion: drop entities in any of these
any_of (&m, r(optional), …)                 // add: keep only entities in at least one of these
matched(w, &m) -> []Entity                   // evaluate; iterate with `for entity in matched(w, &m)`
matcher_destroy(&m)                          // free the matcher (defer it)

// Or build all clauses in one call (none/any optional, pass slice literals):
matcher(all := {r(first), r(second)}, none = {r(excluded)}, any = {r(optional)}) -> Matcher
```
An entity matches if it satisfies all three clauses, e.g. "procs that have an `attr` component but are not `deprecated`":
```odin
m := db.all_of(db.r(procs), db.r(attrs))
db.none_of(&m, db.r(deprecated))
defer db.matcher_destroy(&m)
for entity in db.matched(w, &m) { … }
```

### Emitting output
```odin
emit(w, path, contents)   // record a file; the PostProcess writer flushes it to disk
```

## Shared base facts (`gen_facts`)

Provided once for every declaration, so modules don't re-derive them — and so no
module imports `core:odin/ast`:

```odin
// Classification — use as join filters.
Kind_GenComp   // Other | Proc | Struct | Union  (the declaration's category)
Proc_GenComp   // present if the decl is a proc; carries `no_args: bool`
Struct_GenComp // present if the decl is a struct/union (carries is_union)

// Declaration data — the AST, materialized as plain data.
Attrs_GenComp  // present if the decl has @(...) attributes; carries `attrs: []Attr_Args`
Fields_GenComp // present if the decl is a struct with named fields; carries `fields: []Struct_Field`
```

Use the classification components as join filters, e.g. only proc declarations:

```odin
procs := db.get_comps(w, gen_facts.Proc_GenComp)
m := db.all_of(db.r(decls), db.r(procs))
defer db.matcher_destroy(&m)
for entity in db.matched(w, &m) { … }
```

### Reading declaration facts (no AST)

A struct field is plain data — `Struct_Field{ name, type, tag }`, where `type` is the
rendered type expression (`"Transform"`, `"engine.Tween"`, `"^Foo"`, `"[4]int"`):

```odin
for f in db.get(fields, entity).fields {
    if f.name == "base" && f.type == "Tween" { … }
}
```

An attribute is `Attr_Args{ key, fields: map[string]string, nested: map[string]Attr_Args }`.
A bare `@(poolable)` yields `{key="poolable"}` (present, empty). Read it with the helpers
(so you never touch the map directly for ints / enum names / nested literals):

```odin
attrs := db.get(attrs_comp, entity)            // an ^Attrs_GenComp
if a, ok := gen_facts.attr_find(attrs, "component"); ok {
    menu := a.fields["menu"]                   // string field ("" if absent)
    max  := gen_facts.attr_int(a, "max")       // int field (parses "-N")
}
// enum-variant fields: @(phase={key=app.Phase.Init}) -> "Init"
key := gen_facts.attr_keyname(a, "key")
// nested literals: @(typ_guid={menu_assets_create={menu_name=...}})
if menu, ok := gen_facts.attr_nested(a, "menu_assets_create"); ok { … }
```

`gen_facts` stays agnostic of what any attribute *means*: it flattens every `@(...)` to
strings (resolving same-package string constants), and each module interprets its own keys
and mints its own typed component.

## Adding a new generator

1. Create a `moonhug/prebuild/yourthing_gen/` package.
2. Define a public component type for the facts you extract.
3. In `@(init)`, register a `provider` (tags entities) and a `generator` (emits a file).
   In the provider, read `gen_facts.Attrs_GenComp` / `Fields_GenComp` for the decl data
   you need — do **not** import `core:odin/ast`. If the AST exposes something not yet
   surfaced as a component, add it to `gen_core` (the facade) + `gen_facts`, not your module.
4. Add `import _ "yourthing_gen"` to `prebuild.odin`.

Output ordering must be deterministic (sort before emitting).
