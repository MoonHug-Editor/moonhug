package engine_tests

import "core:testing"
import "moonhug:packages/engine"
import gfx "moonhug:libs/gfx"

// A mesh takes the smallest probe box holding its centre, none outside every box.
@(test)
test_probe_pick_smallest_box :: proc(t: ^testing.T) {
	big := gfx.Cubemap{size = 1}
	small := gfx.Cubemap{size = 2}
	candidates := []engine.Probe_Candidate{
		{min = {-10, -10, -10}, max = {10, 10, 10}, volume = 8000, probe = {cube = &big, intensity = 1}},
		{min = {-1, -1, -1}, max = {1, 1, 1}, volume = 8, probe = {cube = &small, intensity = 1}},
	}
	testing.expect(t, engine.probe_pick(candidates, {0, 0, 0}).cube == &small, "inside both: the smaller box")
	testing.expect(t, engine.probe_pick(candidates, {5, 0, 0}).cube == &big, "inside the big one only")
	testing.expect(t, engine.probe_pick(candidates, {50, 0, 0}).cube == nil, "outside every box: none")
	testing.expect(t, engine.probe_pick(nil, {0, 0, 0}).cube == nil, "no probes: none")
}
