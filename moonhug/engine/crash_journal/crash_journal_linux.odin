#+build linux
package crash_journal

// No ucontext read on linux: the stack starts at the handler, so the crash log
// carries one less frame. Everything else in the journal works.
@(private)
_crash_fault_pc :: proc "contextless" (ctx: rawptr) -> (pc: rawptr, lr: rawptr) {
	return nil, nil
}
