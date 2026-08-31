package sequencer

// ScriptUnion — every script variant a clip can carry, and the lifecycle
// dispatch over them. HAND-WRITTEN for now; this file is the future
// generated artifact (a script_gen scanning packages/ for @(typ_guid) script
// structs and their lifecycle procs, the TweenUnion pattern). Until then, a
// plugin adds a variant by:
//
//   1. shipping a package that imports moonhug:packages/sequencer/core
//      (never the sequencer itself — variants live BELOW the union),
//      declaring a @(typ_guid) struct with any of enter_<Name> /
//      tick_<Name> / exit_<Name>, and destroy_<Name> when it owns heap
//   2. adding the import and the matching cases in this file
//
// Everything else is generic: serialization keys variants by type guid
// (union tags are positional and shift when a variant is added — they are
// never persisted), _resolve_refs_in_value walks into the active variant, so
// Ref_Local fields rebind on load, and the inspector's union drawer offers
// the variants by name.

import "core:encoding/json"
import "moonhug:engine"
import serialization "moonhug:engine/serialization"
import core "moonhug:packages/sequencer/core"
import scripts "moonhug:packages/sequencer/scripts"

ScriptUnion :: union {
	scripts.ScriptSetActive,
	scripts.ScriptLog,
}

// The lifecycle dispatchers. Exhaustive switches are the point: adding a
// variant without its cases here is a compile error, not a clip that
// silently does nothing in play mode. A variant without the phase's proc has
// an empty case.
script_enter :: proc(u: ^ScriptUnion, ctx: ^core.Script_Ctx) {
	switch &v in u {
	case scripts.ScriptSetActive:
		scripts.enter_ScriptSetActive(&v, ctx)
	case scripts.ScriptLog:
		scripts.enter_ScriptLog(&v, ctx)
	}
}

script_tick :: proc(u: ^ScriptUnion, ctx: ^core.Script_Ctx) {
	switch &v in u {
	case scripts.ScriptSetActive:
		// no tick proc
	case scripts.ScriptLog:
		scripts.tick_ScriptLog(&v, ctx)
	}
}

script_exit :: proc(u: ^ScriptUnion, ctx: ^core.Script_Ctx) {
	switch &v in u {
	case scripts.ScriptSetActive:
		scripts.exit_ScriptSetActive(&v, ctx)
	case scripts.ScriptLog:
		scripts.exit_ScriptLog(&v, ctx)
	}
}

// Frees whatever heap the active variant owns and clears the union.
script_destroy :: proc(u: ^ScriptUnion) {
	switch &v in u {
	case scripts.ScriptSetActive:
		// no heap
	case scripts.ScriptLog:
		scripts.destroy_ScriptLog(&v)
	}
	u^ = nil
}

@(phase={key=SerializationInit, order=2})
script_union_serialization_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	// Guid-keyed union persistence (engine/serialization): the variant's
	// @(typ_guid) is the wire tag. Variant pointer types come from the
	// generated register_type calls; the union's own is registered here for
	// undo capture ([dynamic]ScriptUnion fields — silently no-ops without
	// it, docs/Undo.md).
	json.register_user_marshaler(ScriptUnion, serialization.union_marshal)
	json.register_user_unmarshaler(ScriptUnion, serialization.union_unmarshal)
	engine.register_pointer_type(ScriptUnion)
}
