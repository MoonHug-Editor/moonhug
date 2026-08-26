package animation

// PlayableDirector runtime: builds a playable graph from the timeline's
// animation tracks (per-track mixer under a layer-mixer root, one clip node
// per timeline clip), advances time, sets clip node times and ease weights,
// evaluates, and ticks registry tracks with the frame's time window.
//
// The evaluate step is a pure function of director time, so scrubbing is
// director_set_time + director_evaluate — the sequencer window's preview and
// a future timeline Control Track both ride it.

import "core:math"
import "moonhug:engine"

@(update={order=2})
directors_tick :: proc(dt: f32) {
	w := engine.ctx_world()
	it := engine.pool_iterator(playable_directors(w))
	for d, _ in engine.pool_next(&it) {
		if !d.enabled do continue
		if !engine.pool_valid(&w.transforms, engine.Handle(d.owner)) do continue
		if !engine.transform_active_in_hierarchy(d.owner) do continue
		director_tick(d, dt)
	}
}

// --- Playback control (Unity's Play/Pause/Stop) --------------------------------

director_play :: proc(d: ^PlayableDirector) {
	d.started = true
	d.playing = true
}

director_pause :: proc(d: ^PlayableDirector) {
	d.playing = false
}

director_stop :: proc(d: ^PlayableDirector) {
	d.playing = false
	d.time = 0
	d.prev_time = 0
}

// One director's advance — public so tests drive it without a frame loop.
director_tick :: proc(d: ^PlayableDirector, dt: f32) {
	tl, ok := timeline_load(engine.Asset_GUID(d.timeline.guid))
	if !ok do return
	if !d.started {
		d.started = true
		d.playing = !d.manual_start
	}
	if !d.playing do return
	_director_ensure_built(d, tl)

	speed := d.speed if d.speed > 0 else 1
	d.prev_time = d.time
	d.time += dt * speed

	wrapped := false
	dur := timeline_duration(tl)
	if dur > 0 {
		switch d.wrap {
		case .Loop:
			if d.time >= dur {
				d.time = math.mod(d.time, dur)
				wrapped = true
			}
		case .Once:
			if d.time >= dur {
				d.time = dur
				d.playing = false
			}
		}
	}
	_director_evaluate(d, tl, wrapped, scrub = false)
}

// Jump to a time and evaluate — the scrub path. Stateful registry tracks see
// scrub=true and reset instead of firing crossings.
director_set_time :: proc(d: ^PlayableDirector, time: f32) {
	tl, ok := timeline_load(engine.Asset_GUID(d.timeline.guid))
	if !ok do return
	_director_ensure_built(d, tl)
	d.prev_time = time
	d.time = time
	_director_evaluate(d, tl, wrapped = false, scrub = true)
}

@(private = "file")
_director_ensure_built :: proc(d: ^PlayableDirector, tl: ^Timeline) {
	if d.built do return
	d.built = true
	playable_output_init(&d.output, engine.Transform_Handle(d.owner))
	root := playable_add(&d.output.graph, Layer_Mixer_Playable{})
	d.output.graph.root = root
	d.track_nodes = make([dynamic]Track_Nodes, len(tl.tracks))
	for &track, ti in tl.tracks {
		if track.kind != "animation" do continue
		tn := &d.track_nodes[ti]
		tn.mixer = playable_add(&d.output.graph, Mixer_Playable{})
		playable_connect(&d.output.graph, root, tn.mixer, 1)
		tn.clips = make([dynamic]Playable_Handle, 0, len(track.clips))
		for &c in track.clips {
			node := playable_add(&d.output.graph, Clip_Playable{clip = c.asset})
			playable_connect(&d.output.graph, tn.mixer, node, 0)
			append(&tn.clips, node)
		}
	}
}

// Ease-in/out weight ramp inside the clip's span, 0 outside. Overlapping
// clips crossfade through the mixer's normalization.
@(private = "file")
_clip_weight :: proc(c: ^Timeline_Clip, t: f32) -> f32 {
	if t < c.start || t >= c.start + c.duration do return 0
	w := f32(1)
	if c.ease_in > 0 do w = min(w, (t - c.start) / c.ease_in)
	if c.ease_out > 0 do w = min(w, (c.start + c.duration - t) / c.ease_out)
	return clamp(w, 0, 1)
}

@(private = "file")
_director_evaluate :: proc(d: ^PlayableDirector, tl: ^Timeline, wrapped: bool, scrub: bool) {
	for &track, ti in tl.tracks {
		if track.kind == "animation" {
			tn := &d.track_nodes[ti]
			for &c, ci in track.clips {
				w := track.muted ? 0 : _clip_weight(&c, d.time)
				playable_set_input_weight(&d.output.graph, tn.mixer, tn.clips[ci], w)
				if w <= 0 do continue
				n := playable_node(&d.output.graph, tn.clips[ci])
				if n == nil do continue
				local := (d.time - c.start) * (c.speed if c.speed > 0 else 1)
				// A source clip shorter than the timeline clip wraps by its
				// own wrap mode (Unity loops the source).
				if src, sok := animation_clip_load(c.asset); sok {
					local, _ = animation_wrap_time(local, src.length, src.wrap)
				}
				n.time = local
			}
			continue
		}
		if track.muted do continue
		desc, has := track_desc(track.kind)
		if !has do continue
		ctx := Track_Ctx{
			track     = &track,
			target    = _director_binding(d, i32(ti)),
			prev_time = d.prev_time,
			time      = d.time,
			wrapped   = wrapped,
			duration  = timeline_duration(tl),
			scrub     = scrub,
		}
		desc.tick(&ctx)
	}
	playable_output_tick(&d.output)
}

@(private = "file")
_director_binding :: proc(d: ^PlayableDirector, track: i32) -> engine.Ref_Local {
	for &b in d.bindings {
		if b.track == track do return b.target
	}
	return {}
}
