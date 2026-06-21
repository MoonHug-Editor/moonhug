package gen_db

// gen_db is the data substrate for the prebuild code generator: a tiny,
// explicit in-memory database. It holds one entity per declaration; modules
// attach components (extracted facts) and query them to build code.
//
//   PreProcess  - optional setup before any data exists. The built-in scan runs
//                 LAST here: one shared AST walk turns every Odin declaration
//                 into an entity carrying a `DeclInfo`.
//   Provide     - each *_gen module walks the decls and adds its own components
//                 (extracted facts) to the entities it cares about.
//   Generate    - each module queries the component combinations it needs and
//                 emits `GeneratedFile`s (it does NOT write to disk).
//   PostProcess - one built-in writer flushes every GeneratedFile to disk.
//
// Stages run strictly in order, so every provider finishes before any generator
// runs. Within a stage, systems run sorted by `name` for reproducible output.
//
// Modules register from an `@(init)` proc, so adding a module is "drop in a
// package + import it once" - no edits to the harness.
//
// --- Data model (this is the whole thing) ---
//
//   Entity        - just an index; one per declaration found by the scan.
//   Comps(T) - the store of one component type: a dense `rows` array (for
//                   whole-collection walks) plus an `of: map[Entity]int` (Entity ->
//                   row index, for "does this entity have a T, and where"). A
//                   plain map under the hood; nothing to size or pre-allocate.
//   Registry      - the World owns one Comps per component TYPE, keyed by
//                   typeid. A provider creates/fills its store with
//                   `get_or_create_comps(w, T)`; any module fetches the
//                   SAME store with `get_comps(w, T)` - by type, without
//                   importing the provider. This is what makes components
//                   shareable: producer and consumer are decoupled.
//   Query         - a join over N stores: entities present in ALL (AllOf), or
//                   composed with none_of/any_of. Iterate entity-first with
//                   `ents_all_of` or store-first with `query`/`next`.
//
// To extend: declare a public `Foo_GenComp` component type, register
// `provider`/`generator` procs in an `@(init)`, fill
// `get_or_create_comps(w, Foo_GenComp)` in the provider, and read
// `get_comps(w, Foo_GenComp)` in the generator (or in ANY other module's
// generator). No private store, no setup proc, no capacity - a map just grows.

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:odin/ast"
import "../gen_core"

// Entity identifies one declaration. It is the row index of that declaration's
// DeclInfo, assigned by the scan in deterministic (sorted) order.
Entity :: distinct int

// Comps(T) is a component store. `rows` holds the components densely (in entity
// order) for whole-collection walks; `of` maps an Entity to its row so a component
// can be looked up or tested for presence. Adding never fails and never
// relocates existing rows, so a provider may add to entities it is iterating.
Comps :: struct($T: typeid) {
	rows: [dynamic]T,
	ents: [dynamic]Entity, // ents[i] is the Entity owning rows[i]
	of:   map[Entity]int,  // Entity -> row index
}

// World is the shared database handed to every system. It owns the entity
// counter and the central component registry. EVERY component store - the
// built-in DeclInfo/GeneratedFile and every module's components alike - lives in
// the registry, keyed by component type, so any module can reach any component
// by type (see `get_or_create_comps` / `get_comps`). Nothing is module-private.
World :: struct {
	entity_count: int,
	comps:        map[typeid]rawptr, // component typeid -> ^Comps(T)
}

// DeclInfo is attached to one entity per top-level declaration found by the
// shared scan. It carries everything a provider needs, so no provider
// re-parses or re-walks packages.
DeclInfo :: struct {
	name:      string, // declaration identifier (names[0]), "" if not a simple ident
	file_path: string, // map key from pkg.files
	pkg_path:  string, // path passed to ParsePackage (e.g. "moonhug/editor")
	decl:      ^ast.Value_Decl,
	file:      ^ast.File,
	pkg:       ^ast.Package,
}

// GeneratedFile is emitted by generators and consumed by the single PostProcess
// writer. Keeping write-to-disk in one place isolates the side effect.
GeneratedFile :: struct {
	path:     string,
	contents: string,
}

///////////////////////////////////////////////////////////////////////////////
// Comps operations

// comps_len is the number of components in the store.
comps_len :: proc(t: ^Comps($T)) -> int {
	return len(t.rows)
}

// get_entity returns the Entity owning row `i` (the inverse of `of`). Used by
// providers that walk `decls.rows` by index and need the owning entity.
get_entity :: proc(t: ^Comps($T), #any_int i: int) -> Entity {
	return t.ents[i]
}

// add_component attaches a zeroed T to `e` and returns a pointer to it. If the
// entity already has one, the existing component is returned (idempotent). The
// returned error is always nil - a map grows on demand - and exists only so
// call sites can keep their `comp, err := add_component(...)` shape.
add_component :: proc(t: ^Comps($T), e: Entity) -> (component: ^T, err: Maybe(string)) {
	if row, ok := t.of[e]; ok {
		return &t.rows[row], nil
	}
	append(&t.rows, T{})
	append(&t.ents, e)
	t.of[e] = len(t.rows) - 1
	return &t.rows[len(t.rows) - 1], nil
}

// get reads (or writes, through the returned pointer) the component for `e`;
// nil if `e` has no T. The same call reads or writes: `x := get(c,e)^` reads,
// `get(c,e).field = v` writes.
get :: proc(t: ^Comps($T), e: Entity) -> ^T {
	row, ok := t.of[e]
	if !ok do return nil
	return &t.rows[row]
}

// has reports whether `e` carries a T.
has :: proc(t: ^Comps($T), e: Entity) -> bool {
	_, ok := t.of[e]
	return ok
}

// set attaches a T to `e` (adding if absent) and overwrites it with `value`;
// returns a pointer to the stored component.
set :: proc(t: ^Comps($T), e: Entity, value: T) -> ^T {
	c, _ := add_component(t, e)
	c^ = value
	return c
}

///////////////////////////////////////////////////////////////////////////////
// Central component registry.
//
// The World owns one store per component type, keyed by typeid. This is what
// makes components SHAREABLE: a provider creates/fills a store with `get_or_create_comps`,
// and ANY other module fetches the same store with `get_comps` - by type, never
// by importing the provider. The system that produces a component and the
// systems that consume it are decoupled through this registry (the
// context owns all components).
//
//   // provider (Provide stage): create-or-get my store, fill it
//   procs := gen_db.get_or_create_comps(w, Proc_GenComp)
//   gen_db.set(procs, e, Proc_GenComp{...})
//
//   // any consumer (Generate stage): fetch the SAME comps by type
//   procs := gen_db.get_comps(w, Proc_GenComp)
//   for e in gen_db.ents_all_of(gen_db.comps_ref(procs)) { ... }

// get_or_create_comps returns the shared store for type T, creating and registering it on
// first use. Idempotent: every call for the same T returns the same store.
get_or_create_comps :: proc(w: ^World, $T: typeid) -> ^Comps(T) {
	if existing, ok := w.comps[T]; ok {
		return cast(^Comps(T))existing
	}
	t := new(Comps(T))
	w.comps[T] = t
	return t
}

// get_comps fetches the shared store for type T from anywhere. Returns nil if no
// provider has registered T yet (i.e. the component is never produced).
get_comps :: proc(w: ^World, $T: typeid) -> ^Comps(T) {
	if existing, ok := w.comps[T]; ok {
		return cast(^Comps(T))existing
	}
	return nil
}

///////////////////////////////////////////////////////////////////////////////
// Querying: build a Matcher, evaluate it to a list of entities.
//
//   m := gen_db.all_of(gen_db.r(decls), gen_db.r(tweens))  // present in both
//   gen_db.none_of(&m, gen_db.r(deprecated))               // ...and not deprecated
//   defer gen_db.matcher_destroy(&m)
//   for e in gen_db.matched(w, &m) {                        // -> []Entity
//       d := gen_db.get(decls, e)
//       t := gen_db.get(tweens, e)
//   }
//
// A Matcher is a value: reusable, passable, evaluated as many times as you like.
// `get`/`has`/`set` read/write a component on an entity (see below).

// Comps_Ref names one component store inside a query, type-erased so a single
// query can mix stores of different component types. Build it with `comps_ref`
// (or the short alias `r`). It captures just what the matcher needs: membership,
// length (to pick the smallest driving store), and entity-by-index.
Comps_Ref :: struct {
	data: rawptr,
	has:  proc(data: rawptr, e: Entity) -> bool,
	len:  proc(data: rawptr) -> int,
	ent:  proc(data: rawptr, i: int) -> Entity,
}

// comps_ref wraps a typed `^Comps(T)` as a Comps_Ref. `r` is a short alias for
// use at call sites: `all_of(r(decls), r(tweens))`.
comps_ref :: proc(t: ^Comps($T)) -> Comps_Ref {
	return Comps_Ref{
		data = t,
		has  = proc(data: rawptr, e: Entity) -> bool {
			c := cast(^Comps(T))data
			_, ok := c.of[e]
			return ok
		},
		len = proc(data: rawptr) -> int {
			return len((cast(^Comps(T))data).rows)
		},
		ent = proc(data: rawptr, i: int) -> Entity {
			return (cast(^Comps(T))data).ents[i]
		},
	}
}

r :: comps_ref

// Matcher composes the three conditions; an entity matches if it satisfies all:
//   all_of  - in EVERY listed store   (the join; required, at least one)
//   none_of - in NONE of them         (exclusion)
//   any_of  - in AT LEAST ONE of them (only enforced if the clause is non-empty)
Matcher :: struct {
	all:    [dynamic]Comps_Ref,
	none:   [dynamic]Comps_Ref,
	any:    [dynamic]Comps_Ref,
	result: [dynamic]Entity,    // reused buffer for matched()
}

// matcher builds a full matcher in one call. `all` is required (the join); `none`
// and `any` are optional. Pass each clause as a slice literal:
//
//   m := gen_db.matcher({r(decls), r(tweens)})                       // AllOf only
//   m := gen_db.matcher({r(decls), r(procs)}, none = {r(deprecated)}) // ...and NOT deprecated
//   defer gen_db.matcher_destroy(&m)
//   for e in gen_db.matched(w, &m) { ... }
//
// Equivalent to all_of(..) + none_of(..) + any_of(..); use whichever reads better.
matcher :: proc(all: []Comps_Ref, none: []Comps_Ref = nil, any: []Comps_Ref = nil) -> Matcher {
	m: Matcher
	append(&m.all,  ..all)
	append(&m.none, ..none)
	append(&m.any,  ..any)
	return m
}

// all_of starts a matcher requiring every listed store (the common case). Pair
// with none_of / any_of to add clauses, or use `matcher` to build in one call.
all_of :: proc(comps: ..Comps_Ref) -> Matcher {
	m: Matcher
	append(&m.all, ..comps)
	return m
}

// none_of adds an exclusion clause: matched entities must be in none of these.
none_of :: proc(m: ^Matcher, comps: ..Comps_Ref) {
	append(&m.none, ..comps)
}

// any_of adds an "at least one of these" clause.
any_of :: proc(m: ^Matcher, comps: ..Comps_Ref) {
	append(&m.any, ..comps)
}

// matcher_destroy frees a matcher's clause lists and its last result.
matcher_destroy :: proc(m: ^Matcher) {
	delete(m.all)
	delete(m.none)
	delete(m.any)
	delete(m.result)
}

// matched evaluates the matcher and returns the matching entities, sorted by
// Entity (deterministic regardless of which store drove the scan). The slice is
// owned by the matcher and reused on the next call - iterate it, don't keep it
// across another matched() on the same matcher. Drives from the smallest all_of
// store so cost scales with the smallest required set.
matched :: proc(w: ^World, m: ^Matcher) -> []Entity {
	clear(&m.result)
	if len(m.all) == 0 do return m.result[:]

	smallest := 0
	for c, i in m.all {
		if c.len(c.data) < m.all[smallest].len(m.all[smallest].data) {
			smallest = i
		}
	}
	driver := m.all[smallest]

	outer: for i in 0 ..< driver.len(driver.data) {
		e := driver.ent(driver.data, i)
		for c, ci in m.all {
			if ci == smallest do continue
			if !c.has(c.data, e) do continue outer
		}
		for c in m.none {
			if c.has(c.data, e) do continue outer
		}
		if len(m.any) > 0 {
			found := false
			for c in m.any {
				if c.has(c.data, e) { found = true; break }
			}
			if !found do continue outer
		}
		append(&m.result, e)
	}

	slice.sort(m.result[:])
	return m.result[:]
}
///////////////////////////////////////////////////////////////////////////////
// Pipeline: stages, system registry, run_all.

Stage :: enum {
	PreProcess,
	Provide,
	Generate,
	PostProcess,
}

Runner :: proc(w: ^World) -> bool

System :: struct {
	name:  string,
	stage: Stage,
	order: int, // ordering tier WITHIN a stage; lower runs first, then by name
	run:   Runner,
}

// Systems are registered from module @(init) procs, which must be contextless.
// A fixed-capacity backing array keeps registration allocation-free. Modules no
// longer need a setup proc: a component store is created lazily by the first
// gen_db.get_or_create_comps(w, T) call, so there is nothing to initialize up front.
@(private) _MAX :: 64
@(private) _systems: [_MAX]System
@(private) _system_count: int
@(private) _packages: []string

register :: proc "contextless" (sys: System) {
	_systems[_system_count] = sys
	_system_count += 1
}

// Stage-named registration helpers; call sites read as the stage they belong to.
// `order` is the tier WITHIN a stage (default 0): lower runs first, then by name.
// Pass a negative order to run before peers (e.g. a provider of shared base facts
// that other providers compose against), or a positive one to run after.
pre_processor  :: proc "contextless" (name: string, run: Runner, order := 0) { register({name, .PreProcess,  order, run}) }
provider       :: proc "contextless" (name: string, run: Runner, order := 0) { register({name, .Provide,     order, run}) }
generator      :: proc "contextless" (name: string, run: Runner, order := 0) { register({name, .Generate,    order, run}) }
post_processor :: proc "contextless" (name: string, run: Runner, order := 0) { register({name, .PostProcess, order, run}) }

// get_comps_DeclInfo exposes the shared DeclInfo comps - the most-queried component -
// as a convenience. Equivalent to get_comps(w, DeclInfo). Reads from a
// package-level World pointer set by run_all.
@(private) _world: ^World
get_comps_DeclInfo :: proc() -> ^Comps(DeclInfo) { return get_comps(_world, DeclInfo) }

// emit records an output file for the PostProcess writer. `contents` is cloned
// so callers may safely destroy their string builder after emitting. The
// GeneratedFile comps is just another registry component.
emit :: proc(w: ^World, path: string, contents: string) -> bool {
	e := Entity(w.entity_count)
	w.entity_count += 1
	f, _ := add_component(get_or_create_comps(w, GeneratedFile), e)
	f^ = GeneratedFile{path = path, contents = strings.clone(contents)}
	return true
}

// run_all executes the full pipeline over `packages`:
//   1. PreProcess systems (the built-in scan runs last, creating decl entities)
//   2. Provide systems
//   3. Generate systems
//   4. PostProcess systems (built-in writer flushes GeneratedFiles to disk)
// Systems run in (Stage, order, name) order for reproducibility. Component
// comps are created lazily on first use, so there is no setup phase.
run_all :: proc(packages: []string) -> bool {
	w: World
	_world = &w
	_packages = packages
	defer _world = nil

	// Always-present built-in systems, registered like any module's. The scan
	// runs at the LAST PreProcess tier (order +1) so any real pre-processor runs
	// before declarations exist.
	pre_processor("gen_db/scan", _scan, order = +1)
	post_processor("gen_db/write", _write_generated_files)

	systems := _systems[:_system_count]
	slice.sort_by(systems, proc(a, b: System) -> bool {
		if a.stage != b.stage do return a.stage < b.stage
		if a.order != b.order do return a.order < b.order
		return a.name < b.name
	})

	if !_run_stage(&w, systems, .PreProcess) do return false
	if !_run_stage(&w, systems, .Provide) do return false
	if !_run_stage(&w, systems, .Generate) do return false
	if !_run_stage(&w, systems, .PostProcess) do return false
	return true
}

@(private)
_run_stage :: proc(w: ^World, systems: []System, stage: Stage) -> bool {
	for sys in systems {
		if sys.stage != stage do continue
		if !sys.run(w) {
			fmt.eprintf("gen_db: system '%s' failed\n", sys.name)
			return false
		}
	}
	return true
}

// _scan parses every package once and creates one DeclInfo entity per top-level
// declaration. Files are walked in sorted path order so entity creation order -
// and thus every generator's tie-breaking - is reproducible.
@(private)
_scan :: proc(w: ^World) -> bool {
	for pkg_path in _packages {
		pkg, ok := gen_core.ParsePackage(pkg_path)
		if !ok do return false

		file_paths: [dynamic]string
		defer delete(file_paths)
		for file_path in pkg.files do append(&file_paths, file_path)
		slice.sort(file_paths[:])

		for file_path in file_paths {
			file := pkg.files[file_path]
			for decl in file.decls {
				v_decl, is_value := decl.derived.(^ast.Value_Decl)
				if !is_value do continue

				name := ""
				if len(v_decl.names) > 0 {
					if id, id_ok := v_decl.names[0].derived.(^ast.Ident); id_ok {
						name = id.name
					}
				}

				e := Entity(w.entity_count)
				w.entity_count += 1
				info, _ := add_component(get_or_create_comps(w, DeclInfo), e)
				info^ = DeclInfo{
					name      = name,
					file_path = file_path,
					pkg_path  = pkg_path,
					decl      = v_decl,
					file      = file,
					pkg       = pkg,
				}
			}
		}
	}
	return true
}

@(private)
_write_generated_files :: proc(w: ^World) -> bool {
	files := get_comps(w, GeneratedFile)
	if files == nil do return true
	for &f in files.rows[:comps_len(files)] {
		if !gen_core.WriteGeneratedFile(f.path, f.contents) do return false
	}
	return true
}
