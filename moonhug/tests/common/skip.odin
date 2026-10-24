package tests_common

// Skipping a test whose optional tool is missing. Odin's test runner has no
// skipped state: a test that returns early counts as passed. So `skip` also
// records the test in SKIPS_FILE, and `mh test` lists what that file holds
// after the runner's summary (tools/mh/build.odin). Use it only for a tool a
// plugin builds and a machine may lack, such as CoACD, never for a broken
// fixture or a bug.

import "core:fmt"
import "core:log"
import "core:os"
import "core:testing"

// mh test empties it before a run. tools/mh/build.odin names the same path.
SKIPS_FILE :: "builds/test_skips.txt"

// Logs and records why the calling test does not run. The caller returns
// right after. `reason` names what is missing and what provides it.
skip :: proc(t: ^testing.T, reason: string, loc := #caller_location) {
	log.warnf("skipped: %s", reason)
	f, err := os.open(SKIPS_FILE, {.Write, .Create, .Append})
	// Unrecorded, the skip would read as a pass.
	if err != nil do testing.fail_now(t, fmt.tprintf("skipped (%s), and %s cannot be written: %v", reason, SKIPS_FILE, err))
	defer os.close(f)
	fmt.fprintfln(f, "%s\t%s", loc.procedure, reason)
}
