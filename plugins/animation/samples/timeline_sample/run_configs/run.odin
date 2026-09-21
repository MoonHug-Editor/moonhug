package run

// Run configuration (docs/Plugins.md): one call does it all. Plain: build the
// app runner as builds/timeline_sample, export the timeline demo's data dir, run the export. Alt: dev run against the
// editor's live catalog. Shift: run the last build. Alt+Shift: build only.
// The editor's Play passes its live-scene snapshot as the program argument,
// which takes priority for the run.

import rc "moonhug:editor/runconfig"

// The app normalizes its cwd to moonhug/, so the scene path is moonhug-relative.
SCENE :: "packages/timeline_sample/assets/timeline_demo.scene"

main :: proc() {
	rc.play({package_path = "moonhug/packages/app", out = "builds/timeline_sample"}, SCENE)
}
