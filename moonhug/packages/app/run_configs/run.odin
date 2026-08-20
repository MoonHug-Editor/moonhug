package run

// Run configuration (docs/Plugins.md): the editor's Play dropdown lists every
// packages/*/run_configs/*.odin by filename, compiles the picked one, and runs
// it from the REPO ROOT with the live-scene snapshot path as an argument.
// build_and_run forwards that argument to the game. Works identically from a
// terminal: `odin run moonhug/packages/app/run_configs/run.odin -file
// -collection:moonhug=moonhug`.

import rc "moonhug:editor/runconfig"

main :: proc() {
	rc.build_and_run({package_path = "moonhug/packages/app", out = "builds/app"})
}
