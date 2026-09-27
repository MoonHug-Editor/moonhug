package sprites_sequencer_tests

// The sprites fade tween (sprites/sequencer) as a TweenUnion variant.

import "core:testing"
import "moonhug:engine"
import seq "moonhug:packages/sequencer"
import sprites "moonhug:packages/sprites"
import common "moonhug:tests/common"
import sprites_seq "moonhug:packages/sprites/sequencer"

// The PLUGIN path: TweenFadeTo lives in packages/sprites and reaches the
// union only through tween_gen's scan — the sequencer never imports sprites.
// If this compiles and runs, a package added a variant with no sequencer
// edit, which is the whole contract.
@(test)
test_tween_plugin_variant_from_sprites :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	seq.register_builtin_tracks()

	root := engine.transform_new("Stage")
	engine.scene_set_root(tc.scene, root)
	vH := engine.transform_new("Sprite", root)
	_, raw := engine.transform_add_comp(vH, .SpriteRenderer)
	sr := cast(^sprites.SpriteRenderer)raw
	sr.color = {1, 1, 1, 1}
	srh := engine.Handle{}
	if tr := engine.pool_get(&tc.world.transforms, engine.Handle(vH)); tr != nil {
		for c in tr.components do if c.handle.type_key == .SpriteRenderer do srh = c.handle
	}

	_, draw_ := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^seq.PlayableDirector)draw_
	d.enabled = true
	d.duration = 2
	defer seq.director_teardown(d)

	track := _mk_track(root, .TrackTween, seq.Clip_View{start = 0, duration = 1})
	clip := _first_clip_node(&tc.world, track)
	_, tclip := seq.get_comp(clip, seq.ClipTween)
	if tclip == nil do return
	append(&tclip.tweens, seq.TweenUnion(sprites_seq.TweenFadeTo{
		target = {handle = srh},
		to     = 0,
	}))

	seq.director_set_time(d, 0.5) // clip-local 0.5: alpha halfway to 0
	testing.expect(t, abs(sr.color.a - 0.5) < 0.001, "the plugin variant poses through the union")
	seq.director_set_time(d, 1.5) // past the span
	testing.expect(t, abs(sr.color.a - 0) < 0.001)
	seq.director_preview_end(d)
	testing.expect(t, abs(sr.color.a - 1) < 0.001, "preview end restores through the generic base")
}

@(private = "file")
// Build a track NODE with clip NODES under `owner` — what the window's Add
// Track/Add Clip produce. Reuses the view struct as the clip parameter.
_mk_track :: proc(owner: engine.Transform_Handle, kind: engine.TypeKey, clips: ..seq.Clip_View) -> engine.Transform_Handle {
	desc, _ := seq.track_desc(kind)
	node := engine.transform_new(desc.label, owner)
	engine.transform_get_or_add_comp(node, seq.TimelineTrack)
	engine.transform_add_comp(node, kind)
	for c in clips {
		cn := engine.transform_new(len(c.name) > 0 ? c.name : "clip", node)
		_, cc := engine.transform_get_or_add_comp(cn, seq.TimelineClip)
		cc.start = c.start
		cc.duration = c.duration
		cc.ease_in = c.ease_in
		cc.ease_out = c.ease_out
		cc.speed = c.speed
		if desc.clip_key != engine.INVALID_TYPE_KEY do engine.transform_add_comp(cn, desc.clip_key)
	}
	return node
}

@(private = "file")
// The clip node of `track`'s first clip (the tests build one clip per track
// unless stated).
_first_clip_node :: proc(w: ^engine.World, track: engine.Transform_Handle) -> engine.Transform_Handle {
	t := engine.pool_get(&w.transforms, engine.Handle(track))
	if t == nil || len(t.children) == 0 do return {}
	return engine.Transform_Handle(t.children[0].handle)
}
