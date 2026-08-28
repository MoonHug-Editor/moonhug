#+build darwin
package crash_journal

import "core:c"
import darwin "core:sys/darwin"

// The trap frame breaks the frame-pointer chain, so libc backtrace inside a
// handler cannot see the faulting function — its walk starts at the handler.
// The real PC/LR live in the signal's ucontext, so read them and prepend.
// Minimal darwin layout: only the mcontext pointer's position matters.
@(private = "file")
_Ucontext :: struct {
	onstack:  c.int,
	sigmask:  u32,
	ss_sp:    rawptr,
	ss_size:  c.size_t,
	ss_flags: c.int,
	link:     rawptr,
	mcsize:   c.size_t,
	mcontext: rawptr, // ^_Mcontext_Arm64
}

// _STRUCT_MCONTEXT64: exception state first, then the thread state.
@(private = "file")
_Mcontext_Arm64 :: struct #packed {
	es_far: u64,
	es_esr: u32,
	es_exc: u32,
	thread: darwin.arm_thread_state64_t,
}

@(private)
_crash_fault_pc :: proc "contextless" (ctx: rawptr) -> (pc: rawptr, lr: rawptr) {
	if ctx == nil do return nil, nil
	uc := (^_Ucontext)(ctx)
	if uc.mcontext == nil do return nil, nil
	when ODIN_ARCH == .arm64 {
		mc := (^_Mcontext_Arm64)(uc.mcontext)
		return rawptr(uintptr(mc.thread.pc)), rawptr(uintptr(mc.thread.lr))
	} else {
		return nil, nil
	}
}
