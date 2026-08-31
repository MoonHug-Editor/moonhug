package sequencer_scripts

// The built-in script variants. A variant is a @(typ_guid) struct (the
// authored payload — the guid keys serialization, so never change it) plus
// whichever lifecycle procs it implements: enter_<Name>, tick_<Name>,
// exit_<Name>, and destroy_<Name> when it owns heap. All are OPTIONAL —
// ScriptUnion (sequencer/script_union.odin) routes only to the procs a
// variant declares.
//
// This package sits BELOW the union on purpose: it imports sequencer/core
// and engine only, exactly like a plugin's script package would, so the
// built-ins prove the same path plugins take.

import "moonhug:engine"
import "moonhug:engine/log"
import core "moonhug:packages/sequencer/core"

// The target transform is active for the clip's span: enter sets `active`,
// exit sets it back. The scripted form of the activation track — use it when
// activation is one step among several.
@(typ_guid={guid = "47ffdc20-4c80-45b6-b3ae-faee0e68d770"})
SetActiveScript :: struct {
	target: engine.Ref_Local `ref:"Transform"`,
	active: bool,
}

enter_SetActiveScript :: proc(s: ^SetActiveScript, ctx: ^core.Script_Ctx) {
	_set_active(s, s.active)
}

exit_SetActiveScript :: proc(s: ^SetActiveScript, ctx: ^core.Script_Ctx) {
	_set_active(s, !s.active)
}

@(private = "file")
_set_active :: proc(s: ^SetActiveScript, active: bool) {
	w := engine.ctx_world()
	if !engine.pool_valid(&w.transforms, s.target.handle) do return
	if t := engine.pool_get(&w.transforms, s.target.handle); t != nil {
		t.is_active = active
	}
}

// Writes to the log — the editor console during Play, stdout standalone. An
// empty message skips its phase, so one script probes any subset of the
// lifecycle. The "did my timeline get here" probe.
@(typ_guid={guid = "243d224a-cb62-4150-93bf-e5db61ecd6ce"})
LogScript :: struct {
	enter: string,
	tick:  string,
	exit:  string,
}

enter_LogScript :: proc(s: ^LogScript, ctx: ^core.Script_Ctx) {
	if s.enter != "" do log.info(s.enter)
}

tick_LogScript :: proc(s: ^LogScript, ctx: ^core.Script_Ctx) {
	if s.tick != "" do log.info(s.tick)
}

exit_LogScript :: proc(s: ^LogScript, ctx: ^core.Script_Ctx) {
	if s.exit != "" do log.info(s.exit)
}

destroy_LogScript :: proc(s: ^LogScript) {
	// Component strings live on context.allocator, like every other
	// component field: scene load, the union unmarshaler, the inspector's
	// string drawer and undo's apply all allocate with it.
	delete(s.enter)
	delete(s.tick)
	delete(s.exit)
	s^ = {}
}
