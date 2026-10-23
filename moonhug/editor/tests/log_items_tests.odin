package editor_tests

// A log entry carries the items its message is about, through every form:
// the plain message with one item or a list, and the formatted message with
// items named after its arguments. The console's badge reads entry.items.

import "core:testing"
import core "moonhug:libs/core"
import "moonhug:libs/log"

@(test)
test_log_entries_carry_their_items :: proc(t: ^testing.T) {
	log.clear()
	defer log.clear()

	obj := core.Transform_Handle(core.Handle{index = 3, generation = 1})
	asset := core.Asset_GUID{0 = 1, 1 = 2, 2 = 3}

	last :: proc() -> log.Entry { return log.entries[len(log.entries) - 1] }

	log.info("plain")
	testing.expect_value(t, len(last().items), 0)

	log.warning("one", log.Item{label = "Cube", object = obj})
	testing.expect_value(t, len(last().items), 1)
	testing.expect_value(t, last().items[0].label, "Cube")
	testing.expect(t, last().items[0].object == obj, "the item keeps its object")

	two := []log.Item{{label = "Cube", object = obj}, {label = "a.scene", asset = asset}}
	log.error("two", two)
	testing.expect_value(t, len(last().items), 2)
	testing.expect(t, last().items[1].asset == asset, "the second item keeps its asset")

	log.infof("formatted %d", 7)
	testing.expect_value(t, last().message, "formatted 7")
	testing.expect_value(t, len(last().items), 0)

	log.errorf("formatted %d", 8, item = log.Item{label = "Cube", object = obj})
	testing.expect_value(t, len(last().items), 1)

	log.warningf("formatted %d", 9, items = two)
	testing.expect_value(t, last().message, "formatted 9")
	testing.expect_value(t, len(last().items), 2)
}
