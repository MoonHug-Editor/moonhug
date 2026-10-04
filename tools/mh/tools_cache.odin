package mh

// The repo's own tools (prebuild, the generator pruner, the dependency
// gatherer) compiled once into builds/tools/ and reused while their sources
// are older than the binary. Odin has no build cache, so `odin run`
// recompiled each of them on every command, about 1.5 s per make.
// `mh clean` empties builds/, which is the reset.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

TOOLS_DIR :: "builds/tools"

// The binary for the tool whose package is `src`, built with `args` when it
// is missing or any .odin file under `src` or `deps` is newer than it.
tool_bin :: proc(name, src: string, deps: []string, args: ..string) -> (bin: string, ok: bool) {
	bin = fmt.tprintf("%s/%s%s", TOOLS_DIR, name, EXE)
	bin_t, berr := os.modification_time_by_path(bin)
	stale := berr != nil
	if !stale && _any_odin_newer(src, bin_t) do stale = true
	if !stale do for d in deps do if _any_odin_newer(d, bin_t) { stale = true; break }
	if !stale do return bin, true

	os.make_directory_all(TOOLS_DIR)
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "odin", "build", src)
	append(&cmd, ..args)
	append(&cmd, fmt.tprintf("-out:%s", bin))
	return bin, step(fmt.tprintf("%s build", name), ..cmd[:])
}

// The gen/ folder of every installed package: the generators prebuild
// compiles in (docs/core/Plugins.md, "Package generators").
package_gen_dirs :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	handle, err := os.open("moonhug/packages")
	if err != nil do return out[:]
	defer os.close(handle)
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil do return out[:]
	for e in entries {
		if strings.has_prefix(e.name, ".") do continue
		gen := fmt.tprintf("moonhug/packages/%s/gen", e.name)
		if info, serr := os.stat(gen, context.temp_allocator); serr == nil && info.type == .Directory do append(&out, gen)
	}
	return out[:]
}

// Whether any .odin file under `dir` (links followed) is newer than `t`.
@(private = "file")
_any_odin_newer :: proc(dir: string, t: time.Time) -> bool {
	handle, err := os.open(dir)
	if err != nil do return false
	defer os.close(handle)
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil do return false
	for e in entries {
		if strings.has_prefix(e.name, ".") do continue
		full := fmt.tprintf("%s/%s", dir, e.name)
		info, serr := os.stat(full, context.temp_allocator) // follows a link
		if serr != nil do continue
		if info.type == .Directory {
			if _any_odin_newer(full, t) do return true
			continue
		}
		if strings.has_suffix(e.name, ".odin") && time.diff(t, info.modification_time) > 0 do return true
	}
	return false
}
