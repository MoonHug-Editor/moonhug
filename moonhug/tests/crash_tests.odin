package tests

// Crash journal (docs/CrashJournal.md). The signal path itself can't be
// exercised in-process — a real SIGSEGV would take the test runner down —
// so `moonhug_editor --crash-test` covers that end to end. These cover the
// journal-writing path and the breadcrumb, which is where the content bugs
// would be.

import "core:os"
import "core:strings"
import "core:testing"
import crash_journal "../engine/crash_journal"

@(test)
test_crash_journal_writes_reason_and_breadcrumb :: proc(t: ^testing.T) {
	crash_journal.init()
	path := crash_journal.path()
	testing.expect(t, path != "", "journal path should be built at init")
	if path == "" do return
	defer os.remove(path)

	crash_journal.breadcrumb("unit test breadcrumb")
	crash_journal.write_test_entry("TEST (synthetic entry)")

	data, rerr := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, rerr == nil, "journal file should exist after a write")
	if rerr != nil do return
	text := string(data)

	testing.expect(t, strings.contains(text, "MoonHug crash"), "header")
	testing.expect(t, strings.contains(text, "TEST (synthetic entry)"), "reason")
	testing.expect(t, strings.contains(text, "unit test breadcrumb"), "breadcrumb")
	testing.expect(t, strings.contains(text, "stack:"), "stack section")
}

@(test)
test_crash_journal_breadcrumb_clear_and_overwrite :: proc(t: ^testing.T) {
	crash_journal.init()
	path := crash_journal.path()
	if path == "" do return
	defer os.remove(path)

	// The breadcrumb is last-activity, not a trail: a second call replaces
	// the first rather than appending.
	crash_journal.breadcrumb("first activity")
	crash_journal.breadcrumb("second activity")
	crash_journal.write_test_entry("TEST")
	data, _ := os.read_entire_file(path, context.temp_allocator)
	text := string(data)
	testing.expect(t, strings.contains(text, "second activity"), "latest breadcrumb wins")
	testing.expect(t, !strings.contains(text, "first activity"), "previous breadcrumb replaced")

	crash_journal.breadcrumb_clear()
	crash_journal.write_test_entry("TEST")
	data2, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, !strings.contains(string(data2), "doing:"), "cleared breadcrumb omits the line")
}

@(test)
test_crash_journal_breadcrumb_truncates_long_text :: proc(t: ^testing.T) {
	crash_journal.init()
	path := crash_journal.path()
	if path == "" do return
	defer os.remove(path)

	// Fixed storage: an over-long breadcrumb must truncate, never overflow.
	long := strings.repeat("x", 4096, context.temp_allocator)
	crash_journal.breadcrumb(long)
	crash_journal.write_test_entry("TEST")

	data, rerr := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, rerr == nil)
	if rerr != nil do return
	testing.expect(t, len(data) < 4096, "breadcrumb should be capped, not written whole")
}
