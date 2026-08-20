#+build linux
package crash_journal

@(private)
_crash_fault_pc :: proc "contextless" (ctx: rawptr) -> (pc: rawptr, lr: rawptr) {
	return nil, nil
}
