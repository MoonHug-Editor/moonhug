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
	testing.expect(t, engine.probe_pick(candidates, {0, 0, 0}).probe.cube == &small, "inside both: the smaller box")
	testing.expect(t, engine.probe_pick(candidates, {5, 0, 0}).probe.cube == &big, "inside the big one only")
	testing.expect(t, engine.probe_pick(candidates, {50, 0, 0}).probe.cube == nil, "outside every box: none")
	testing.expect(t, engine.probe_pick(nil, {0, 0, 0}).probe.cube == nil, "no probes: none")
	testing.expect(t, engine.probe_pick(candidates, {0, 0, 0}).weight == 1, "no blend distance: the whole probe")
}

// Within a box's blend distance of its edge a mesh fades into the next
// smaller box holding it, or the environment when none does.
@(test)
test_probe_pick_blends_near_the_edge :: proc(t: ^testing.T) {
	big := gfx.Cubemap{size = 1}
	small := gfx.Cubemap{size = 2}
	candidates := []engine.Probe_Candidate{
		{min = {-10, -10, -10}, max = {10, 10, 10}, volume = 8000, blend = 2, probe = {cube = &big, intensity = 1}},
		{min = {-1, -1, -1}, max = {1, 1, 1}, volume = 8, blend = 1, probe = {cube = &small, intensity = 1}},
	}
	centre := engine.probe_pick(candidates, {0, 0, 0})
	testing.expect(t, centre.probe.cube == &small && centre.weight == 1 && centre.other.cube == nil, "a blend distance from every face: the whole probe, nothing to blend")
	edge := engine.probe_pick(candidates, {0.75, 0, 0})
	testing.expect(t, edge.probe.cube == &small && edge.other.cube == &big, "near the small box's face: blends with the big one")
	testing.expectf(t, abs(edge.weight - 0.25) < 1e-5, "a quarter of the blend distance inside: weight 0.25, got %v", edge.weight)
	outer := engine.probe_pick(candidates, {9, 0, 0})
	testing.expect(t, outer.probe.cube == &big && outer.other.cube == nil, "near the big box's face: blends with the environment")
	testing.expectf(t, abs(outer.weight - 0.5) < 1e-5, "half the blend distance inside: weight 0.5, got %v", outer.weight)
}
