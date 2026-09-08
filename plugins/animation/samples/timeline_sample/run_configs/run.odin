package run

// Run configuration (docs/Plugins.md): plays the timeline demo scene through
// the app runner. The editor's Play passes its live-scene snapshot as the
// program argument, which takes priority.

import "core:os"
import rc "moonhug:editor/runconfig"

// The app normalizes its cwd to moonhug/, so the default scene path is
// moonhug-relative.
SCENE :: "packages/timeline_sample/assets/timeline_demo.scene"

main :: proc() {
	cfg := rc.Config{package_path = "moonhug/packages/app", out = "builds/app"}
	if len(os.args) > 1 {
		rc.build_and_run(cfg)
	} else {
		rc.build_and_run(cfg, SCENE)
	}
}
