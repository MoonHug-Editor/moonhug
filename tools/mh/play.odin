package mh

// `mh play [<package>[:<config>]] [--dev|--run-only|--build-only]`: run a
// package's run configuration from the terminal, the same program the
// editor's Play button runs. A run config is `packages/<pkg>/run_configs/
// <config>.odin`. With one argument part it is the package and the config is
// `run`. With no argument and exactly one package shipping run configs, that
// package is picked. The flags are the editor's modifier keys: Alt is --dev,
// Shift is --run-only, Alt+Shift is --build-only.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

Run_Config :: struct {
	pkg:    string, // "app"
	config: string, // "run"
	path:   string, // moonhug/packages/app/run_configs/run.odin
}

cmd_play :: proc(args: []string) -> int {
	configs := run_configs()
	if len(configs) == 0 {
		fmt.eprintln("mh: no run configurations installed (packages/<pkg>/run_configs/<config>.odin)")
		return 1
	}
	target := ""
	flags := make([dynamic]string, context.temp_allocator)
	for a in args {
		if strings.has_prefix(a, "--") {
			append(&flags, a)
		} else {
			target = a
		}
	}
	pkg, config := target, "run"
	if colon := strings.index_byte(target, ':'); colon >= 0 {
		pkg, config = target[:colon], target[colon + 1:]
	}
	if pkg == "" {
		pkgs := make([dynamic]string, context.temp_allocator)
		for c in configs do if !slice_has(pkgs[:], c.pkg) do append(&pkgs, c.pkg)
		if len(pkgs) != 1 {
			fmt.eprintln("mh: several packages ship run configurations, name one:")
			for c in configs do fmt.eprintfln("  mh play %s:%s", c.pkg, c.config)
			return 1
		}
		pkg = pkgs[0]
	}
	for c in configs {
		if c.pkg != pkg || c.config != config do continue
		if !prebuild() do return 1
		cmd := make([dynamic]string, context.temp_allocator)
		append(&cmd, "odin", "run", c.path, "-file", COLLECTION)
		if len(flags) > 0 {
			append(&cmd, "--")
			append(&cmd, ..flags[:])
		}
		return run(..cmd[:])
	}
	fmt.eprintfln("mh: no run configuration %s:%s, installed ones:", pkg, config)
	for c in configs do fmt.eprintfln("  mh play %s:%s", c.pkg, c.config)
	return 1
}

// Every `<pkg>/run_configs/*.odin` under moonhug/packages, links followed.
run_configs :: proc(allocator := context.temp_allocator) -> []Run_Config {
	out := make([dynamic]Run_Config, allocator)
	pkgs, err := filepath.glob(PACKAGES_DIR + "/*/run_configs/*.odin", allocator)
	if err != nil do return out[:]
	for p in pkgs {
		slashed, _ := strings.replace_all(p, "\\", "/", allocator)
		parts := strings.split(slashed, "/", allocator)
		if len(parts) < 5 do continue
		pkg := parts[len(parts) - 3]
		config := strings.trim_suffix(parts[len(parts) - 1], ".odin")
		append(&out, Run_Config{pkg = pkg, config = config, path = p})
	}
	return out[:]
}

@(private = "file")
slice_has :: proc(list: []string, s: string) -> bool {
	for x in list do if x == s do return true
	return false
}
