package core

// Runs a proc at a lifecycle phase: startup, entering and leaving play, importer
// and editor init, and phases that packages add.
//
// `key` is the Phase value and `order` sorts procs inside a phase. `mode =
// Editor` marks a proc that runs only in the editor. The proc takes no
// arguments. A package adds phases with a `Phase_Extra` enum of its own.
//
// Every phase subscriber has this signature. The enum itself is generated into
// phases_generated.odin from the phases the installed packages declare.
@(extension_point={attribute="phase", target="proc", fields="key order mode"})
Phase_Proc :: proc()
