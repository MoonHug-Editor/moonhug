package prof

// PROF=all: the compiler calls _enter at the start of every proc of the
// program and _exit at its end, and each kept proc is a zone.
//
// Kept: procs of this repository. Dropped: Odin's own packages (base, core,
// vendor), which are small and called very often. A proc with
// @(no_instrumentation) is never seen here.
//
// Both procs run inside every proc, so they call nothing the compiler marks:
// no core package, no bounds check, only intrinsics and Tracy's C procs.
//
// Each proc's place is worked out once and kept in _slots, keyed by the
// proc's address. Each thread keeps the zones it has open in _open, so an
// exit ends the zone its enter began.

import "base:intrinsics"
import "base:runtime"

// Both imports are used only in the all mode.
_ :: intrinsics
_ :: runtime

when MODE == "all" {

	@(private = "file") _SLOT_BITS :: 16
	@(private = "file") _SLOT_COUNT :: 1 << _SLOT_BITS
	@(private = "file") _PROBES :: 32
	@(private = "file") _NAME_BYTES :: 4 << 20
	@(private = "file") _MAX_OPEN :: 512

	@(private = "file")
	_State :: enum u32 {
		Empty,
		Filling,
		Keep,
		Drop,
	}

	@(private = "file")
	_Slot :: struct {
		addr:  rawptr,
		state: _State,
		loc:   _Location,
	}

	@(private = "file") _slots: [_SLOT_COUNT]_Slot
	// Copies of proc and file names with a 0 at the end, as Tracy reads them.
	@(private = "file") _names: [_NAME_BYTES]u8
	@(private = "file") _names_used: int

	@(private = "file", thread_local) _open: [_MAX_OPEN]Zone
	@(private = "file", thread_local) _depth: int

	@(instrumentation_enter, no_instrumentation)
	_enter :: proc "contextless" (proc_address, call_site: rawptr, loc: runtime.Source_Code_Location) {
		#no_bounds_check {
			d := _depth
			_depth = d + 1
			if d >= _MAX_OPEN do return
			_open[d] = {}
			if ___tracy_connected() == 0 do return
			slot := _slot(proc_address, loc)
			if slot == nil do return
			_open[d] = ___tracy_emit_zone_begin(&slot.loc, 1)
		}
	}

	@(instrumentation_exit, no_instrumentation)
	_exit :: proc "contextless" (proc_address, call_site: rawptr, loc: runtime.Source_Code_Location) {
		#no_bounds_check {
			d := _depth - 1
			if d < 0 do return
			_depth = d
			if d >= _MAX_OPEN do return
			if _open[d].active != 0 do ___tracy_emit_zone_end(_open[d])
		}
	}

	// The kept slot of a proc, nil for a dropped one.
	@(private = "file", no_instrumentation)
	_slot :: proc "contextless" (addr: rawptr, loc: runtime.Source_Code_Location) -> ^_Slot {
		#no_bounds_check {
			h := (uintptr(addr) * 0x9E3779B97F4A7C15) >> (64 - _SLOT_BITS)
			for probe in 0 ..< uintptr(_PROBES) {
				s := &_slots[(h + probe) & (_SLOT_COUNT - 1)]
				cur := intrinsics.atomic_load(&s.addr)
				if cur == nil {
					old, won := intrinsics.atomic_compare_exchange_strong(&s.addr, nil, addr)
					if won {
						intrinsics.atomic_store(&s.state, _State.Filling)
						keep := _fill(s, loc)
						intrinsics.atomic_store(&s.state, _State.Keep if keep else _State.Drop)
						return s if keep else nil
					}
					cur = old
				}
				if cur == addr {
					return s if intrinsics.atomic_load(&s.state) == .Keep else nil
				}
			}
			return nil
		}
	}

	@(private = "file", no_instrumentation)
	_fill :: proc "contextless" (s: ^_Slot, loc: runtime.Source_Code_Location) -> bool {
		if _has_prefix(loc.file_path, ODIN_ROOT) do return false
		function := _keep_name(loc.procedure)
		file := _keep_name(loc.file_path)
		if function == nil || file == nil do return false
		s.loc = {function = function, file = file, line = u32(loc.line)}
		return true
	}

	@(private = "file", no_instrumentation)
	_has_prefix :: proc "contextless" (s, prefix: string) -> bool {
		if len(s) < len(prefix) do return false
		a, b := raw_data(s), raw_data(prefix)
		#no_bounds_check for i in 0 ..< len(prefix) {
			if a[i] != b[i] do return false
		}
		return true
	}

	@(private = "file", no_instrumentation)
	_keep_name :: proc "contextless" (s: string) -> cstring {
		n := len(s) + 1
		end := intrinsics.atomic_add(&_names_used, n) + n
		if end > _NAME_BYTES do return nil
		dst := ([^]u8)(&_names)[end - n:]
		src := raw_data(s)
		#no_bounds_check for i in 0 ..< len(s) do dst[i] = src[i]
		dst[len(s)] = 0
		return cstring(dst)
	}

}
