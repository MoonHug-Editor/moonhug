package prof

// prof: marks for the Tracy profiler (moonhug/external/tracy).
//
//   prof.zone()                // this proc, until it returns
//   prof.zone("sort quads")    // a named scope, until the scope ends
//   prof.frame_mark()          // once a frame
//   prof.plot("draw calls", f64(n))
//   prof.message("scene loaded")
//   prof.thread_name("asset job")
//
// The build picks the mode with -define:PROF=<mode> (make build PROF=zones):
//
//   none   every proc here is empty, the Tracy client is not linked. The default.
//   zones  the marks above are live.
//   all    as zones, and every proc of the program is a zone too (prof_all.odin).
//
// The client records nothing until a viewer connects, and listens on this
// machine only (build_tracy.sh).

MODE :: #config(PROF, "none")
#assert(MODE == "none" || MODE == "zones" || MODE == "all", "PROF is none, zones or all")

ENABLED :: MODE != "none"

when ENABLED {

	// A zone that began, for zone_end. Tracy's ___tracy_c_zone_context as
	// built with TRACY_ON_DEMAND.
	Zone :: struct {
		id:         u32,
		active:     i32,
		connection: u64,
	}

	// A named zone that ends with the scope it is called in. With no name it
	// shows as the calling proc.
	@(deferred_out = zone_end, no_instrumentation)
	zone :: proc "contextless" (name := "", loc := #caller_location) -> Zone {
		return zone_begin(name, loc)
	}

	@(no_instrumentation)
	zone_begin :: proc "contextless" (name := "", loc := #caller_location) -> Zone {
		if ___tracy_connected() == 0 do return {}
		// In the all mode the calling proc is a zone already.
		when MODE == "all" do if name == "" do return {}
		id: u64
		if name == "" {
			id = ___tracy_alloc_srcloc(u32(loc.line), raw_data(loc.file_path), len(loc.file_path), raw_data(loc.procedure), len(loc.procedure), 0)
		} else {
			id = ___tracy_alloc_srcloc_name(u32(loc.line), raw_data(loc.file_path), len(loc.file_path), raw_data(loc.procedure), len(loc.procedure), raw_data(name), len(name), 0)
		}
		return ___tracy_emit_zone_begin_alloc(id, 1)
	}

	@(no_instrumentation)
	zone_end :: proc "contextless" (z: Zone) {
		if z.active != 0 do ___tracy_emit_zone_end(z)
	}

	// The end of a frame. The viewer cuts its timeline here.
	@(no_instrumentation)
	frame_mark :: proc "contextless" () {
		___tracy_emit_frame_mark(nil)
	}

	// One point of a graph under the timeline. `name` is a literal: Tracy
	// tells graphs apart by the pointer.
	@(no_instrumentation)
	plot :: proc "contextless" (name: cstring, value: f64) {
		___tracy_emit_plot(name, value)
	}

	// A line on the timeline.
	@(no_instrumentation)
	message :: proc "contextless" (text: string) {
		___tracy_emit_logString(_SEVERITY_INFO, 0, 0, len(text), raw_data(text))
	}

	// Names the calling thread in the viewer. `name` is a literal.
	@(no_instrumentation)
	thread_name :: proc "contextless" (name: cstring) {
		___tracy_set_thread_name(name)
	}

	// True while a viewer is connected.
	@(no_instrumentation)
	connected :: proc "contextless" () -> bool {
		return ___tracy_connected() != 0
	}

	@(private)
	_SEVERITY_INFO :: 2

	// Tracy's ___tracy_source_location_data: a zone's place, kept for the
	// life of the program.
	@(private)
	_Location :: struct {
		name:     cstring,
		function: cstring,
		file:     cstring,
		line:     u32,
		color:    u32,
	}

	// builds/tracy/libtracy.a, made by build_tracy.sh (mh builds it when it
	// is missing).
	foreign import tracy {"../../../builds/tracy/libtracy.a", "system:c++"}

	@(private, default_calling_convention = "c")
	foreign tracy {
		___tracy_connected :: proc() -> i32 ---
		___tracy_set_thread_name :: proc(name: cstring) ---
		___tracy_alloc_srcloc :: proc(line: u32, source: [^]u8, source_len: uint, function: [^]u8, function_len: uint, color: u32) -> u64 ---
		___tracy_alloc_srcloc_name :: proc(line: u32, source: [^]u8, source_len: uint, function: [^]u8, function_len: uint, name: [^]u8, name_len: uint, color: u32) -> u64 ---
		___tracy_emit_zone_begin :: proc(loc: ^_Location, active: i32) -> Zone ---
		___tracy_emit_zone_begin_alloc :: proc(srcloc: u64, active: i32) -> Zone ---
		___tracy_emit_zone_end :: proc(z: Zone) ---
		___tracy_emit_frame_mark :: proc(name: cstring) ---
		___tracy_emit_plot :: proc(name: cstring, value: f64) ---
		___tracy_emit_logString :: proc(severity: i8, color: i32, callstack_depth: i32, size: uint, text: [^]u8) ---
	}

} else {

	Zone :: struct {}

	@(deferred_out = zone_end)
	zone :: #force_inline proc "contextless" (name := "", loc := #caller_location) -> Zone { return {} }
	zone_begin :: #force_inline proc "contextless" (name := "", loc := #caller_location) -> Zone { return {} }
	zone_end :: #force_inline proc "contextless" (z: Zone) {}
	frame_mark :: #force_inline proc "contextless" () {}
	plot :: #force_inline proc "contextless" (name: cstring, value: f64) {}
	message :: #force_inline proc "contextless" (text: string) {}
	thread_name :: #force_inline proc "contextless" (name: cstring) {}
	connected :: #force_inline proc "contextless" () -> bool { return false }

}
