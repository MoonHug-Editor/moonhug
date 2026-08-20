package audio

// Audio importer. Decodes the source (wav/mp3/ogg) to float32 PCM, applies
// the import settings (volume gain), and writes a float32 WAV artifact.
// Playback loads the ARTIFACT, so every consumer hears the mastered result.
// Fully self-contained — the settings type, its defaults (factory) and the
// importer logic all live here. Scene/meta records key on the type guid
// below — never change it.

import "core:fmt"
import "core:os"
import "core:strings"
import sdl "vendor:sdl3"
import mix "vendor:sdl3/mixer"
import engine "moonhug:engine"

@(typ_guid={guid="ec017cc2-7267-45b4-ae80-d6861094d27a", makeProcName=make_pAudioSettings})
AudioSettings :: struct {
	// Gain baked into the artifact's PCM at import (1 = unchanged). Mastering
	// knob — per-instance mixing volume lives on AudioSource.
	volume: f32,
}

make_pAudioSettings :: proc() -> any {
	p := new(AudioSettings)
	p.volume = 1.0
	return p^
}

_AUDIO_EXTS := []string{".mp3", ".wav", ".ogg"}

@(phase={key=ImportersInit, order=1})
audio_importers_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	engine.importer_register({
		name         = "audio",
		version      = 2,
		extensions   = _AUDIO_EXTS,
		settings_tid = typeid_of(AudioSettings),
		run          = _import_audio,
	})
	engine.asset_pipeline_add_reimport_hook(_clip_reimported)
}

// The pipeline creates the artifact directory before calling run.
_import_audio :: proc(source_path: string, artifact_path: string, settings: rawptr) -> bool {
	volume: f32 = 1
	if settings != nil do volume = (cast(^AudioSettings)settings).volume

	pcm, spec, ok := decode_file_f32(source_path)
	if !ok {
		fmt.printf("[Pipeline] Failed to decode audio: %s\n", source_path)
		return false
	}
	defer delete(pcm)

	if volume != 1 {
		for &s in pcm do s *= volume
	}

	if !_write_wav_f32(artifact_path, pcm, spec) {
		fmt.printf("[Pipeline] Failed to write artifact: %s\n", artifact_path)
		return false
	}
	fmt.printf("[Pipeline] Imported audio: %s -> %s\n", source_path, artifact_path)
	return true
}

// Decode any supported source into interleaved float32 PCM at its native
// channel count and sample rate. The caller owns the returned slice.
decode_file_f32 :: proc(path: string, allocator := context.allocator) -> (pcm: []f32, spec: sdl.AudioSpec, ok: bool) {
	_mix_lib_ensure()
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	dec := mix.CreateAudioDecoder(cpath, 0)
	if dec == nil do return
	defer mix.DestroyAudioDecoder(dec)

	native: sdl.AudioSpec
	if !mix.GetAudioDecoderFormat(dec, &native) do return
	spec = sdl.AudioSpec{format = .F32, channels = native.channels, freq = native.freq}

	buf := make([dynamic]f32, allocator)
	chunk: [16384]f32
	for {
		n := mix.DecodeAudio(dec, raw_data(chunk[:]), i32(size_of(chunk)), spec)
		if n <= 0 do break
		append(&buf, ..chunk[:int(n) / size_of(f32)])
	}
	return buf[:], spec, true
}

// Minimal WAVE_FORMAT_IEEE_FLOAT writer (fmt + fact + data chunks).
_write_wav_f32 :: proc(path: string, pcm: []f32, spec: sdl.AudioSpec) -> bool {
	channels := u16(spec.channels)
	rate := u32(spec.freq)
	block_align := u32(channels) * size_of(f32)
	data_size := u32(len(pcm) * size_of(f32))

	out := make([dynamic]u8, 0, int(data_size) + 64, context.temp_allocator)
	w_bytes :: proc(out: ^[dynamic]u8, s: string) { append(out, s) }
	w_u16 :: proc(out: ^[dynamic]u8, v: u16) { append(out, u8(v), u8(v >> 8)) }
	w_u32 :: proc(out: ^[dynamic]u8, v: u32) {
		append(out, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
	}

	w_bytes(&out, "RIFF")
	w_u32(&out, 4 + (8 + 18) + (8 + 4) + (8 + data_size))
	w_bytes(&out, "WAVE")

	w_bytes(&out, "fmt ")
	w_u32(&out, 18)
	w_u16(&out, 3) // WAVE_FORMAT_IEEE_FLOAT
	w_u16(&out, channels)
	w_u32(&out, rate)
	w_u32(&out, rate * block_align)
	w_u16(&out, u16(block_align))
	w_u16(&out, 32) // bits per sample
	w_u16(&out, 0)  // cbSize

	w_bytes(&out, "fact")
	w_u32(&out, 4)
	w_u32(&out, data_size / block_align) // frame count

	w_bytes(&out, "data")
	w_u32(&out, data_size)
	if len(pcm) > 0 {
		append(&out, ..(cast([^]u8)raw_data(pcm))[:data_size])
	}

	return os.write_entire_file(path, out[:]) == nil
}
