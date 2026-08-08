#+build !darwin
#+build !linux
package crash_journal

import "base:runtime"

// Non-POSIX stub: the crash journal needs sigaction + an alternate signal
// stack (docs/CrashJournal.md). Windows would use SetUnhandledExceptionFilter.

init :: proc() {}
assertion_failure :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	runtime.default_assertion_failure_proc(prefix, message, loc)
}
breadcrumb :: proc(text: string) {}
breadcrumb_clear :: proc() {}
write_test_entry :: proc(reason: string) {}
path :: proc() -> string { return "" }
test_crash :: proc() {}
