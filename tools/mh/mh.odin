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
import "core:sys/posix"
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
	{"build", "build the editor without launching it (--no-plugins proves the shell builds alone)", cmd_build, true},
	{"check-noplugins", "check that the editor shell builds with every plugin set aside: one row per stage, PASS or FAIL with the first errors", cmd_check_noplugins, true},
	{"play", "run a package's run configuration: mh play [pkg[:config]] [--dev|--run-only|--build-only]", cmd_play, true},
	{"test", "run the test suite (--name=pkg.test runs one)", cmd_test, true},
	{"prebuild", "run the code generators only", cmd_prebuild, true},
	{"deps", "gather plugin dependencies into mh_plugin.json (names: only those)", cmd_deps, true},
	{"shaders", "recompile the built-in GLSL shaders", cmd_shaders, true},
	{"mcp", "build and run the MCP stdio shim", cmd_mcp, true},
	{"docs", "build the documentation site into builds/docs (--open opens it)", cmd_docs, true},
	{"clean", "remove builds/ (--all also removes the library cache)", cmd_clean, true},
	{"help", "list these commands", cmd_help, false},
}

main :: proc() {
	raise_file_limit()
	refresh_odin_stamp()
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

// The compiler opens an object file per package and more while it links, and
// the editor's relaunch starts mh from a process with macOS's default soft
// limit of 256 open files, which the child inherits: "LLVM Error: Too many
// open files", or a `#load` that cannot open a file that is there. The soft
// limit goes up to the hard one, capped at what the kernel allows a process.
raise_file_limit :: proc() {
	when ODIN_OS == .Darwin || ODIN_OS == .Linux {
		limit: posix.rlimit
		if posix.getrlimit(.NOFILE, &limit) != .OK do return
		want := posix.rlim_t(65536)
		if limit.rlim_max < want do want = limit.rlim_max
		if limit.rlim_cur >= want do return
		limit.rlim_cur = want
		if posix.setrlimit(.NOFILE, &limit) != .OK {
			// macOS refuses a soft limit above kern.maxfilesperproc even when
			// the hard limit says unlimited: OPEN_MAX is what it always takes.
			limit.rlim_cur = 10240
			_ = posix.setrlimit(.NOFILE, &limit)
		}
	}
}
