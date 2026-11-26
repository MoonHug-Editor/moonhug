package audio

// Filters on one source (docs/components/AudioLowPassFilter.md,
// AudioHighPassFilter.md): a component on the AudioSource's object filters
// what that source plays, before its mixer group. An occlusion component
// (audio/physics3d) muffles it the same way, through the source's
// `occlusion`.
//
// The filters run in the source's track callback on the audio thread: high
// pass, low pass, then the occlusion's low pass. audio_update gives them their
// values each frame, under the mixer lock and only when one changed.

import "base:runtime"
import "core:c"
import "core:math"
import sdl "vendor:sdl3"
import mix "vendor:sdl3/mixer"
import engine "moonhug:packages/engine"

@(component={menu="Audio/AudioLowPassFilter", icon="EQUALIZER"})
@(typ_guid={guid="1ffdaaa6-5fe6-423a-9e78-a62061a02ac3"})
AudioLowPassFilter :: struct {
	using base: engine.CompData `inspect:"-"`,
	// Hz: what is above it is muffled.
	cutoff:     f32 `decor:range(10, 22000)`,
	// 1 is a plain slope, more rings at the cutoff.
	resonance:  f32 `decor:range(1, 10)`,
}

type_reset_AudioLowPassFilter :: proc(f: ^AudioLowPassFilter) {
	engine.comp_zero(f)
	f.cutoff = 5000
	f.resonance = 1
}

@(component={menu="Audio/AudioHighPassFilter", icon="EQUALIZER"})
@(typ_guid={guid="03938595-c225-497d-85b2-64d2f2b28e87"})
AudioHighPassFilter :: struct {
	using base: engine.CompData `inspect:"-"`,
	// Hz: what is below it is thinned out.
	cutoff:     f32 `decor:range(10, 22000)`,
	resonance:  f32 `decor:range(1, 10)`,
}

type_reset_AudioHighPassFilter :: proc(f: ^AudioHighPassFilter) {
	engine.comp_zero(f)
	f.cutoff = 5000
	f.resonance = 1
}

// How muffled a source is, set every frame by an occlusion component:
// `amount` from 0 (clear) to 1 (blocked), and what blocked sounds like, a
// low-pass cutoff in Hz and a volume factor. `frame` is audio_frame() when it
// was set: a source no component set for a frame is clear.
Source_Occlusion :: struct {
	amount: f32,
	cutoff: f32,
	volume: f32,
	frame:  u64,
}

// The frame audio_update last ran, counted from 1.
audio_frame :: proc() -> u64 {
	return _audio_frame
}

@(private)
_audio_frame: u64

// The filters of one source's track. Main thread writes under the mixer lock,
// the track callback reads.
Source_DSP :: struct {
	stages: [3]_Source_Filter, // high pass, low pass, occlusion
}

@(private)
_Source_Filter :: struct {
	on:     bool,
	cutoff: f32,
	q:      f32,
	rate:   f32,
	coeffs: Biquad_Coeffs,
	state:  Biquad_State,
}

// Where a source's occlusion gets: its cutoff and volume factor at `amount`.
// The cutoff falls from 22 kHz on a log scale, so half blocked sounds half
// muffled.
occlusion_at :: proc(o: Source_Occlusion) -> (cutoff, volume: f32) {
	a := clamp(o.amount, 0, 1)
	target := clamp(o.cutoff, 10, 22000)
	return 22000 * math.pow(target / 22000, a), 1 + (clamp(o.volume, 0, 1) - 1) * a
}

// Whether the source's occlusion is current and muffles at all.
@(private)
_occluded :: proc(src: ^AudioSource) -> bool {
	return src.occlusion.frame + 1 >= _audio_frame && src.occlusion.amount > 0.001
}

// Gives a source's track the filters its object asks for now.
@(private)
_source_filters_apply :: proc(src: ^AudioSource) {
	if src.track == nil do return
	want: [3]_Source_Filter
	if _, hp := engine.transform_get_comp(src.owner, AudioHighPassFilter); hp != nil && hp.enabled {
		want[0] = {on = true, cutoff = hp.cutoff, q = hp.resonance}
	}
	if _, lp := engine.transform_get_comp(src.owner, AudioLowPassFilter); lp != nil && lp.enabled {
		want[1] = {on = true, cutoff = lp.cutoff, q = lp.resonance}
	}
	if _occluded(src) {
		cutoff, _ := occlusion_at(src.occlusion)
		want[2] = {on = true, cutoff = cutoff, q = 0.7071}
	}
	if src.dsp == nil {
		if !want[0].on && !want[1].on && !want[2].on do return
		src.dsp = new(Source_DSP, runtime.default_allocator())
		_ = mix.SetTrackCookedCallback(src.track, transmute(mix.TrackMixCallback)_source_dsp_mix, src.dsp)
	}
	rate := _mix_rate()
	changed := false
	for w, i in want {
		f := &src.dsp.stages[i]
		if f.on != w.on || (w.on && (f.cutoff != w.cutoff || f.q != w.q || f.rate != rate)) do changed = true
	}
	if !changed do return
	_lock()
	defer _unlock()
	for w, i in want {
		f := &src.dsp.stages[i]
		if !w.on {
			f.on = false
			continue
		}
		// A filter switched on starts from silence, not from what it held.
		if !f.on do f.state = {}
		f.on, f.cutoff, f.q, f.rate = true, w.cutoff, w.q, rate
		f.coeffs = biquad_make(w.cutoff, w.q, rate, high = i == 0)
	}
}

@(private)
_source_dsp_mix :: proc "c" (userdata: rawptr, track: ^mix.Track, spec: ^sdl.AudioSpec, pcm: ^c.float, samples: c.int) {
	dsp := (^Source_DSP)(userdata)
	if dsp == nil || pcm == nil || samples <= 0 || spec == nil do return
	buf := ([^]f32)(pcm)[:samples]
	for &f in dsp.stages do if f.on do biquad_run(buf, int(spec.channels), f.coeffs, &f.state)
}
