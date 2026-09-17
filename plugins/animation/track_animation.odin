package animation

// The animation timeline track (docs/Sequencer.md): clips are AnimationClips
// blended on a per-track mixer, weights from their ease ramps, so overlapping
// clips crossfade. The track drives an ANIMATION COMPONENT (Unity's model:
// the timeline takes over the Animator): its target names the Animation to
// play on, and the component's own playback stands down while the track
// drives it, so the two never write the same transforms in one frame.
// Unset, the track looks for an Animation on the director itself, and falls
// back to posing the director's transform directly when there is none.
//
// Every animation track on one director builds into ONE graph, so two tracks
// aimed at the same object stack instead of overwriting each other. That graph
// lives here, keyed by the director, rather than on Track_Ctx: the sequencer
// package holds no animation knowledge, exactly like audio and particles, so
// it cannot name a Playable_Graph.

import "base:runtime"
import "core:slice"
import "moonhug:engine"
import seq "moonhug:packages/sequencer"

// The kind's components. The clip carries its .anim; the track carries the
// object those clips play on.
@(component={menu="Playables/Tracks/TrackAnimation"})
@(typ_guid={guid = "89aaf6a3-5c2e-4af3-8893-81833e7f79b9"})
TrackAnimation :: struct {
	using base: engine.CompData `inspect:"-"`,

	// The output slot this track drives when a TimelineAnimator owns the
	// timeline. It is the track's own DEFAULT: a state may route this track to
	// a different slot, and a state that routes nothing gets this one. Naming
	// a slot rather than an object is what lets one timeline prefab serve
	// several animators binding different objects.
	key: string,

	// The Animation component this track drives when no animator is involved —
	// the object the clips play on. Its own playback is suppressed while the
	// track drives it. Unset = the director's own object, which is what a
	// timeline authored as a self-contained prefab wants.
	target: engine.Ref_Local `ref:"Animation"`,
}

@(component={menu="Playables/Clips/ClipAnimation"})
@(typ_guid={guid = "d0b0e534-01d0-4b0f-9f2c-1e38daa94c3d"})
ClipAnimation :: struct {
	using base: engine.CompData `inspect:"-"`,

	clip: engine.Asset_GUID `ext:"anim"`,
}

// `key` is heap-owned, so the component needs this under exactly this name:
// type_cleanup dispatches on `cleanup_<Type>`, and undo calls it before
// unmarshalling a restored value.
cleanup_TrackAnimation :: proc(tr: ^TrackAnimation) {
	if tr.key != "" do delete(tr.key)
	tr.key = ""
}

// The .anim a timeline clip plays, or the empty guid.
@(private = "file")
_anim_clip_asset :: proc(c: ^seq.Clip_View) -> engine.Asset_GUID {
	if _, cr := get_comp(c.node, ClipAnimation); cr != nil do return cr.clip
	return {}
}

@(phase={key=ImportersInit, order=4})
animation_track_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	// Process-global, so never the caller's allocator (a test's tracking
	// allocator would dangle) — the rule every registry here follows.
	{
		context.allocator = runtime.default_allocator()
		_director_arenas = make(map[engine.Transform_Handle]^_Director_Arena)
	}
	// An adopted director never ticks itself: the animator owns its time.
	seq.director_register_drive_check(proc(d: ^seq.PlayableDirector) -> bool {
		a, ok := _director_arenas[d.owner]
		return ok && a.adopter != nil
	})
	// A track on an adopted director resolves its key through the animator's
	// outputs. Registered with the sequencer so a track in ANY plugin can ask,
	// without that plugin importing this one — the audio track is the first.
	seq.director_register_key_resolver(proc(director: engine.Transform_Handle, key: string) -> (engine.Transform_Handle, bool) {
		a, ok := _director_arenas[director]
		if !ok || a.adopter == nil do return {}, false
		return timeline_animator_output_owner_for_key(a.adopter, key)
	})
	seq.track_register(seq.Track_Desc{
		track_key   = .TrackAnimation,
		clip_key    = .ClipAnimation,
		label       = "animation",
		build       = _animation_track_build,
		destroy     = _animation_track_destroy,
		tick        = _animation_track_tick,
		preview_end = _animation_track_preview_end,
	})
}

// --- The per-director arena -----------------------------------------------------------
//
// One graph per director, one OUTPUT per distinct target, one layer mixer at
// each output's root. Tracks attach their own mixer to that layer mixer in
// track order, so a later track overrides an earlier one only where it
// animates a channel — instead of the later pose replacing the earlier one
// wholesale, which is what separate graphs did.
//
// Entries are heap-allocated: a pointer into map storage dangles on rehash.
@(private = "file")
_Director_Arena :: struct {
	graph:   Playable_Graph,                  // used only when `adopter` is nil
	targets: map[engine.Transform_Handle]int, // target transform -> output index
	refs:    int,                             // tracks attached

	// ADOPTED: a TimelineAnimator owns this director, so its tracks build into
	// the ANIMATOR's graph instead — one arena would otherwise mean one pose
	// per director applied on its own, which cannot blend with the other
	// states. `parents` is the animator's per-output mixer for the state this
	// director backs, parallel to the animator's outputs, and tracks resolve
	// their output by KEY rather than by their own target.
	adopter: ^TimelineAnimator,
	parents: []Playable_Handle,
}

// The graph a track on this director builds into.
@(private = "file")
_arena_graph :: proc(a: ^_Director_Arena) -> ^Playable_Graph {
	return a.adopter != nil ? &a.adopter.graph : &a.graph
}

// Hand a director to an animator: its tracks stop owning a pose and start
// contributing a subtree under `parents`. Called when a state instantiates its
// timeline, before the director builds, and re-read whenever it rebuilds.
//
// The adoption holds a reference of its own, so the arena survives a rebuild
// that momentarily destroys every track.
animation_director_adopt :: proc(director: engine.Transform_Handle, adopter: ^TimelineAnimator, parents: []Playable_Handle) {
	a := _arena_get_or_make(director)
	if a.adopter == nil do a.refs += 1
	a.adopter = adopter
	// Copied, not borrowed: the arena outlives any caller's slice, and a
	// dangling `parents` is read on every rebuild.
	context.allocator = runtime.default_allocator()
	delete(a.parents)
	a.parents = slice.clone(parents)
}

// Whether a driver has claimed this director's time.
animation_director_is_adopted :: proc(director: engine.Transform_Handle) -> bool {
	a, ok := _director_arenas[director]
	return ok && a.adopter != nil
}

// Drop the adoption reference. The arena goes when its last track goes too.
animation_director_unadopt :: proc(director: engine.Transform_Handle) {
	a, ok := _director_arenas[director]
	if !ok || a.adopter == nil do return
	a.adopter = nil
	context.allocator = runtime.default_allocator()
	delete(a.parents)
	a.parents = nil
	_arena_release(director)
}

@(private = "file")
_director_arenas: map[engine.Transform_Handle]^_Director_Arena

// Arenas outlive whatever context created them — a director built during a
// test keeps its arena until the director is torn down — so every allocation
// here is pinned to the process allocator, never the caller's. Same rule the
// registries follow.
@(private = "file")
_arena_get_or_make :: proc(director: engine.Transform_Handle) -> ^_Director_Arena {
	if a, ok := _director_arenas[director]; ok do return a
	context.allocator = runtime.default_allocator()
	a := new(_Director_Arena)
	playable_graph_init(&a.graph)
	a.targets = make(map[engine.Transform_Handle]int)
	_director_arenas[director] = a
	return a
}

@(private = "file")
_arena_acquire :: proc(director: engine.Transform_Handle) -> ^_Director_Arena {
	a := _arena_get_or_make(director)
	a.refs += 1
	return a
}

@(private = "file")
_arena_release :: proc(director: engine.Transform_Handle) {
	a, ok := _director_arenas[director]
	if !ok do return
	a.refs -= 1
	if a.refs > 0 do return
	context.allocator = runtime.default_allocator()
	playable_graph_destroy(&a.graph)
	delete(a.targets)
	delete(a.parents)
	free(a)
	delete_key(&_director_arenas, director)
}

// The output index for `target`, created with a layer mixer root on first use.
@(private = "file")
_arena_output :: proc(a: ^_Director_Arena, target: engine.Transform_Handle) -> int {
	if idx, ok := a.targets[target]; ok do return idx
	context.allocator = runtime.default_allocator()
	idx := graph_output_add(&a.graph, target)
	root := playable_add(&a.graph, Playable_Layer_Mixer{})
	graph_output(&a.graph, idx).root = root
	a.targets[target] = idx
	return idx
}

// The animator output an adopted track writes to. Its own `key` is the
// default, and the track's `target` is not consulted at all — under an
// animator the scene binding belongs to the animator, not to the timeline.
@(private = "file")
_ta_track_output :: proc(a: ^_Director_Arena, ctx: ^seq.Track_Ctx) -> int {
	if a.adopter == nil do return -1
	key := ""
	if _, at := get_comp(ctx.track.node, TrackAnimation); at != nil do key = at.key
	if key == "" do return -1
	return timeline_animator_output_for_key(a.adopter, key)
}

// Evaluate and apply ONE output. A track flushes its own output at the end of
// its tick, so the pose lands inside the track tick exactly as it did when
// each track owned a graph — which is what keeps the editor's scrub and
// preview paths working, since neither has a post-evaluation hook. Tracks
// sharing an output each flush it, and the last one to tick this frame
// produces the final pose.
@(private = "file")
_arena_flush :: proc(a: ^_Director_Arena, idx: int) {
	// An adopted director never applies: the animator owns the graph and
	// flushes every output once, after every state has set its weights.
	if a.adopter != nil do return
	o := graph_output(&a.graph, idx)
	if o == nil do return
	scripts := make([dynamic]Script_Invocation, context.temp_allocator)
	pose := playable_graph_evaluate(&a.graph, o.root, &o.binding, &scripts)
	animation_pose_apply(&o.binding, pose)
	playable_scripts_fire(scripts[:])
}

// One track: a mixer fed by one clip node per timeline clip, attached to its
// target's output in the director's arena.
@(private = "file")
_Anim_Track :: struct {
	director: engine.Transform_Handle, // arena key
	out:      int,                     // output index within that arena
	mixer:    Playable_Handle,
	clips:    [dynamic]Playable_Handle,
	// The transform the output was resolved for. The director's structural
	// fingerprint does not watch a kind's own fields, so the track notices
	// its own target moving and moves to another output.
	root:     engine.Transform_Handle,
}

// The Animation component the track drives, or nil when it poses a bare
// transform instead (no target and none on the director).
//
// Full resolution order, lowest default first, each overridden from above:
//   1. the director's own transform
//   2. an Animation on the director
//   3. this track's `target`
//   4. this track's `key`, through the owning animator's `targets`
//   5. the playing state's route for this track
// Levels 4 and 5 need a TimelineAnimator owning the timeline, which is what
// adopts the director — until then a track resolves through 1-3 exactly as it
// always has.
@(private = "file")
_animation_track_comp :: proc(ctx: ^seq.Track_Ctx) -> ^Animation {
	w := engine.ctx_world()
	if _, at := get_comp(ctx.track.node, TrackAnimation); at != nil {
		if engine.world_pool_valid(w, at.target.handle) && at.target.handle.type_key == .Animation {
			return cast(^Animation)engine.world_pool_get(w, at.target.handle)
		}
	}
	// Unset: the director's own Animation, when it has one.
	_, a := get_comp(ctx.owner, Animation)
	return a
}

// The transform the track's clips animate: its driven component's owner, or
// the director when it drives none.
@(private = "file")
_animation_track_root :: proc(ctx: ^seq.Track_Ctx) -> engine.Transform_Handle {
	if a := _animation_track_comp(ctx); a != nil do return engine.Transform_Handle(a.owner)
	return ctx.owner
}

@(private = "file")
_animation_track_build :: proc(ctx: ^seq.Track_Ctx) -> rawptr {
	st := new(_Anim_Track)
	st.director = ctx.owner
	st.root = _animation_track_root(ctx)
	a := _arena_acquire(ctx.owner)
	g := _arena_graph(a)
	parent: Playable_Handle
	if a.adopter != nil {
		// Adopted: the output comes from this track's KEY through the
		// animator's bindings, and the subtree hangs under the state's mixer
		// for that output. An unresolved key leaves the track inert rather
		// than posing something arbitrary.
		st.out = _ta_track_output(a, ctx)
		if st.out < 0 || st.out >= len(a.parents) {
			st.out = -1
			st.clips = make([dynamic]Playable_Handle)
			return st
		}
		parent = a.parents[st.out]
	} else {
		st.out = _arena_output(a, st.root)
		parent = graph_output(g, st.out).root
	}
	st.mixer = playable_add(g, Playable_Mixer{})
	playable_connect(g, parent, st.mixer, 1)
	st.clips = make([dynamic]Playable_Handle, 0, len(ctx.track.clips))
	for &c in ctx.track.clips {
		node := playable_add(g, Playable_Clip{clip = _anim_clip_asset(&c)})
		playable_connect(g, st.mixer, node, 0)
		append(&st.clips, node)
	}
	return st
}

@(private = "file")
_animation_track_destroy :: proc(state: rawptr) {
	st := cast(^_Anim_Track)state
	if a, ok := _director_arenas[st.director]; ok {
		g := _arena_graph(a)
		for h in st.clips do playable_remove(g, h)
		playable_remove(g, st.mixer)
	}
	delete(st.clips)
	_arena_release(st.director)
	free(st)
}

@(private = "file")
_animation_track_tick :: proc(ctx: ^seq.Track_Ctx) {
	st := cast(^_Anim_Track)ctx.state
	if st == nil do return
	arena, has_arena := _director_arenas[st.director]
	if !has_arena do return
	if st.out < 0 do return // key resolved to nothing at build
	g := _arena_graph(arena)
	// The driven component stands down: the track owns its object's pose for
	// as long as it is driving. Released in preview_end / on retarget.
	if comp := _animation_track_comp(ctx); comp != nil {
		comp.timeline_driven = true
	}
	// Retarget: move the subtree to the new target's output, then flush the old
	// one ONCE with this track detached. Outputs are only ever flushed by a
	// track that feeds them, so an output this track just abandoned would
	// otherwise never be applied again and its object would stay frozen at the
	// last pose. With nothing feeding it the pose is empty, so the apply writes
	// its bind-time defaults and releases the object. A sibling track still
	// feeding it keeps posing it instead, which is why this flushes rather than
	// forcing defaults.
	if arena.adopter == nil {
		if root := _animation_track_root(ctx); root != st.root {
			old := st.out
			if o := graph_output(g, old); o != nil do playable_disconnect(g, o.root, st.mixer)
			_arena_flush(arena, old)
			st.root = root
			st.out = _arena_output(arena, root)
			playable_connect(g, graph_output(g, st.out).root, st.mixer, 1)
		}
	}
	for &c, ci in ctx.track.clips {
		if ci >= len(st.clips) do break
		w := seq.track_clip_weight(ctx.track.clips, ci, ctx.time)
		playable_set_input_weight(g, st.mixer, st.clips[ci], w)
		if w <= 0 do continue
		n := playable_node(g, st.clips[ci])
		if n == nil do continue
		local := (ctx.time - c.start) * (c.speed if c.speed > 0 else 1)
		// A source clip shorter than the timeline clip wraps by its own wrap
		// mode (Unity loops the source).
		if src, sok := animation_clip_load(_anim_clip_asset(&c)); sok {
			local, _ = animation_wrap_time(local, src.length, src.wrap)
		}
		n.time = local
	}
	_arena_flush(arena, st.out)
}

// The editor's preview restores the authored pose through the same binding
// defaults the animation scrub preview uses.
@(private = "file")
_animation_track_preview_end :: proc(ctx: ^seq.Track_Ctx) {
	st := cast(^_Anim_Track)ctx.state
	if st == nil do return
	if a, ok := _director_arenas[st.director]; ok {
		if o := graph_output(&a.graph, st.out); o != nil {
			animation_binding_write_defaults(&o.binding)
		}
	}
	// Hand the object back to its component.
	if comp := _animation_track_comp(ctx); comp != nil do comp.timeline_driven = false
}

// The track's binding, for the editor's preview bracket: poses are captured
// before evaluation and restored after the render.
animation_track_binding :: proc(state: rawptr) -> ^Animation_Binding {
	st := cast(^_Anim_Track)state
	if st == nil do return nil
	a, ok := _director_arenas[st.director]
	if !ok do return nil
	o := graph_output(&a.graph, st.out)
	return o != nil ? &o.binding : nil
}

// The graph a director's animation tracks build into, or nil. An adopted
// director reports its ADOPTER's graph, which is the one actually evaluated.
animation_director_graph :: proc(director: engine.Transform_Handle) -> ^Playable_Graph {
	a, ok := _director_arenas[director]
	if !ok do return nil
	return _arena_graph(a)
}
