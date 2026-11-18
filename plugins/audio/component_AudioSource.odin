package audio

// AudioSource: a clip reference plus per-instance mixing
// controls. The live SDL3_mixer track is runtime-only.
//
// Its track plays through the mixer group `output` names (mixer_runtime.odin).
// An AudioLowPassFilter or AudioHighPassFilter on its object filters it, and
// an occlusion component muffles it through `occlusion` (filters.odin).

import "base:runtime"
import mix "vendor:sdl3/mixer"
import engine "moonhug:packages/engine"

// ref_tags="Output": something a timeline track can drive. A `has:"@Output"`
// picker offers objects carrying one.
@(component={menu="Audio/AudioSource", ref_tags="Output"})
@(typ_guid={guid="6f7fb020-d764-4ce1-bc09-d8088356bd22"})
AudioSource :: struct {
	using base:    engine.CompData `inspect:"-"`,
	clip:          engine.PPtr `ext:"mp3,wav,ogg"`,
	// The Audio Mixer group it plays through. Unset plays straight to the
	// output.
	output:        engine.PPtr `ext:"mixergroup"`,
	volume:        f32,
	pitch:         f32, // playback frequency ratio (1 = as authored)
	mute:          bool,
	loop:          bool,
	play_on_awake: bool,
	// 0 = 2D (full volume, centered), 1 = 3D (attenuated + panned relative
	// to the AudioListener).
	spatial_blend: f32,
	min_distance:  f32, // full volume inside this radius
	max_distance:  f32, // attenuation stops falling past this radius
	rolloff:       Audio_Rolloff, // how the volume falls between the two

	track:      ^mix.Track `json:"-" inspect:"-"`,
	started:    bool `json:"-" inspect:"-"`,
	// The output the track is routed to, and when (_route_gen).
	routed:     engine.PPtr `json:"-" inspect:"-"`,
	routed_gen: u64 `json:"-" inspect:"-"`,
	// The filters its track runs, made when one is first needed.
	dsp:        ^Source_DSP `json:"-" inspect:"-"`,
	// Set every frame by an occlusion component (audio/physics3d).
	occlusion:  Source_Occlusion `json:"-" inspect:"-"`,
}

type_reset_AudioSource :: proc(comp: ^AudioSource) {
	type_cleanup_AudioSource(comp)
	comp.volume = 1
	comp.pitch = 1
	comp.play_on_awake = true
	comp.min_distance = 1
	comp.max_distance = 500
}

// Runs on destroy, removal, Reset and undo: the track goes with the
// component, or it keeps playing.
type_cleanup_AudioSource :: proc(comp: ^AudioSource) {
	_destroy_track(comp)
	engine.comp_zero(comp)
}

_destroy_track :: proc(comp: ^AudioSource) {
	if comp.track != nil {
		mix.DestroyTrack(comp.track)
		comp.track = nil
	}
	// After the track: its callback no longer runs.
	if comp.dsp != nil {
		free(comp.dsp, runtime.default_allocator())
		comp.dsp = nil
	}
}
