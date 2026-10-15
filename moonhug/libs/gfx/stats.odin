package gfx

// Per-frame render statistics: what the frame asked the GPU to draw and how
// long the CPU spent on it. frame_begin opens a frame's counters, frame_end
// closes them into a ring of recent frames (stats_last, stats_average).
//
// cpu_ms is frame_begin to frame_end without the waits for the GPU (command
// buffer and swapchain acquire). With one frame in flight those waits are
// the GPU finishing the previous frame, so wait_ms grows when the GPU is the
// bottleneck and cpu_ms when the CPU is.

import "core:time"

Frame_Stats :: struct {
	draw_calls: int, // draw commands encoded
	instances:  int, // objects drawn: an instanced draw call draws several
	triangles:  int,
	passes:     int, // render passes begun
	cpu_ms:     f32,
	wait_ms:    f32,
}

STATS_FRAMES :: 120

@(private = "file")
_stats: struct {
	current: Frame_Stats,
	begin:   time.Tick,
	wait:    time.Duration,
	open:    bool,
	ring:    [STATS_FRAMES]Frame_Stats,
	count:   int, // frames recorded, up to STATS_FRAMES
	next:    int,
}

// The last finished frame's statistics.
stats_last :: proc() -> Frame_Stats {
	if _stats.count == 0 do return {}
	return _stats.ring[(_stats.next + STATS_FRAMES - 1) % STATS_FRAMES]
}

// The mean over the last `frames` finished frames (at most STATS_FRAMES).
// Counters are rounded down.
stats_average :: proc(frames := 60) -> (avg: Frame_Stats, n: int) {
	n = min(frames, _stats.count, STATS_FRAMES)
	if n == 0 do return
	draws, instances, tris, passes: int
	for i in 1 ..= n {
		s := _stats.ring[(_stats.next + STATS_FRAMES - i) % STATS_FRAMES]
		draws += s.draw_calls
		instances += s.instances
		tris += s.triangles
		passes += s.passes
		avg.cpu_ms += s.cpu_ms
		avg.wait_ms += s.wait_ms
	}
	avg.draw_calls = draws / n
	avg.instances = instances / n
	avg.triangles = tris / n
	avg.passes = passes / n
	avg.cpu_ms /= f32(n)
	avg.wait_ms /= f32(n)
	return
}

@(private)
_stats_frame_begin :: proc() {
	_stats.current = {}
	_stats.wait = 0
	_stats.begin = time.tick_now()
	_stats.open = true
}

@(private)
_stats_frame_end :: proc() {
	if !_stats.open do return
	_stats.open = false
	total := time.tick_since(_stats.begin)
	_stats.current.cpu_ms = f32(time.duration_milliseconds(total - _stats.wait))
	_stats.current.wait_ms = f32(time.duration_milliseconds(_stats.wait))
	_stats.ring[_stats.next] = _stats.current
	_stats.next = (_stats.next + 1) % STATS_FRAMES
	_stats.count = min(_stats.count + 1, STATS_FRAMES)
}

// Time spent blocked on the GPU, measured around an acquire call.
@(private)
_stats_wait :: proc(since: time.Tick) {
	_stats.wait += time.tick_since(since)
}

@(private)
_stats_draw :: proc(instances, triangles_each: int) {
	_stats.current.draw_calls += 1
	_stats.current.instances += instances
	_stats.current.triangles += instances * triangles_each
}

@(private)
_stats_pass :: proc() {
	_stats.current.passes += 1
}
