package mh

// `mh build --no-plugins`: the proof that the editor shell depends on no
// plugin. Every link in moonhug/packages is moved aside, the prebuild and the
// editor build run against the bare shell and host, and the links come back
// whatever happened. The editor binary goes to a separate file, so the
// installed build is untouched. The last generator pass then regenerates the
// installed state, which is why the prebuild runs again at the end.
//
// A generator that writes into a plugin by path with that plugin absent would
// leave a real directory where the link was. Restore removes such a directory
// before putting the link back, and reports it, since it is a generator bug.

import "core:fmt"
import "core:os"
import "core:path/filepath"

ASIDE_DIR :: "builds/.packages_aside"
NOPLUGINS_BIN :: "builds/MoonHug-noplugins" + EXE

build_without_plugins :: proc() -> bool {
	links := tracked_links()
	if len(links) == 0 {
		fmt.eprintln("mh: no tracked plugin links found, is this the repository root?")
		return false
	}
	os.make_directory_all(ASIDE_DIR)
	moved := make([dynamic]Link_Entry, context.temp_allocator)
	defer _restore_links(moved[:])
	for e in links {
		if link_state(e) == .Missing do continue
		aside, _ := filepath.join({ASIDE_DIR, filepath.base(e.path)}, context.temp_allocator)
		if err := os.rename(e.path, aside); err != nil {
			fmt.eprintfln("mh: cannot move %s aside: %v", e.path, err)
			return false
		}
		append(&moved, e)
	}
	fmt.printfln("mh: %d plugin links aside, building the bare shell", len(moved))
	if !prebuild() do return false
	os.make_directory_all("builds")
	if !step("editor build (no plugins)", "odin", "build", "moonhug/editor", IGNORE_ATTRS, COLLECTION, VET, fmt.tprintf("-out:%s", NOPLUGINS_BIN)) do return false
	fmt.printfln("mh: the shell builds with no plugins, %s", NOPLUGINS_BIN)
	return true
}

@(private = "file")
_restore_links :: proc(moved: []Link_Entry) {
	for e in moved {
		if os.exists(e.path) {
			// Only a generator writing into an absent plugin produces this.
			fmt.eprintfln("mh: %s was recreated as a real directory during the no-plugins build (a generator wrote into an absent plugin), removing it", e.path)
			os.remove_all(e.path)
		}
		aside, _ := filepath.join({ASIDE_DIR, filepath.base(e.path)}, context.temp_allocator)
		if err := os.rename(aside, e.path); err != nil {
			fmt.eprintfln("mh: cannot restore %s from %s: %v (mh setup repairs links from the index)", e.path, aside, err)
		}
	}
	os.remove(ASIDE_DIR)
	// Back to the installed state: generated files changed with the plugins gone.
	fmt.println("mh: links restored, regenerating the installed state")
	if !prebuild() do fmt.eprintln("mh: regenerating the installed state failed, run mh prebuild")
}
