package mh

// mh — the repo's build and run entry point.
//
//   odin run tools/mh -- <command>      works anywhere Odin does, no setup
//   make <command>                      the same thing, shorter, if you have make
//
// A tool, not a script: shell scripts need a .sh and a .bat to cover every
// platform, and the two drift. Odin is already a hard dependency of this repo,
// so one program covers all of them — the same reasoning run configs already
// use (moonhug/editor/runconfig).
//
// The Makefile only FORWARDS to these commands. It holds no build knowledge,
// so there is one definition of how this repo builds and it lives here.
//
// This tool imports nothing from the moonhug collection on purpose: it must
// compile before the repo does, and needs no -collection flag to run.

import "core:fmt"
import "core:os"
import "core:strings"

VERSION :: "1.0.0"

Command :: struct {
	name:    string,
	summary: string,
	run:     proc(args: []string) -> int,
	// Commands that touch the repo run from its root, so relative paths mean
	// the same thing from any directory. help and setup do not: help needs no
	// repo at all, and setup only builds libraries in the Odin installation.
	in_repo: bool,
}

COMMANDS := []Command {
	{"setup", "build the vendored Odin libraries this repo links against", cmd_setup, false},
	{"run", "build and launch the editor", cmd_run, true},
	{"debug", "build with -debug and launch the editor", cmd_debug, true},
	{"build", "build the editor without launching it", cmd_build, true},
	{"app", "build and run the game (packages/app)", cmd_app, true},
	{"test", "run the test suite (--name=pkg.test runs one)", cmd_test, true},
	{"prebuild", "run the code generators only", cmd_prebuild, true},
	{"shaders", "recompile the built-in GLSL shaders", cmd_shaders, true},
	{"mcp", "build and run the MCP stdio shim", cmd_mcp, true},
	{"clean", "remove builds/ (--all also removes the library cache)", cmd_clean, true},
	{"help", "list these commands", cmd_help, false},
}

main :: proc() {
	args := os.args[1:]
	if len(args) == 0 {
		os.exit(cmd_help(nil))
	}
	name := args[0]
	for c in COMMANDS {
		if c.name == name {
			if c.in_repo && !chdir_repo_root() do os.exit(1)
			os.exit(c.run(args[1:]))
		}
	}
	fmt.eprintfln("mh: unknown command %q", name)
	cmd_help(nil)
	os.exit(1)
}

cmd_help :: proc(args: []string) -> int {
	fmt.println("mh — MoonHug build tool")
	fmt.println()
	fmt.println("  odin run tools/mh -- <command>     (no dependencies)")
	fmt.println("  make <command>                     (same, if you have make)")
	fmt.println()
	for c in COMMANDS {
		fmt.printfln("  %-9s %s", c.name, c.summary)
	}
	fmt.println()
	fmt.println("First time in a fresh clone: run setup, then run.")
	return 0
}

// --- flags -----------------------------------------------------------------

// has_flag reports whether "--name" was passed.
has_flag :: proc(args: []string, name: string) -> bool {
	for a in args do if a == name do return true
	return false
}

// flag_value reads "--name=value", returning "" when absent.
flag_value :: proc(args: []string, name: string) -> string {
	prefix := strings.concatenate({name, "="}, context.temp_allocator)
	for a in args {
		if strings.has_prefix(a, prefix) do return a[len(prefix):]
	}
	return ""
}
