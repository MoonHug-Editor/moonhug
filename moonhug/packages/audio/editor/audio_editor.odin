package audio_editor

// Audio preview pane: transport + waveform in the Project Inspector's
// bottom Preview section for any audio source file. The waveform renders
// the ARTIFACT (mastered PCM), downsampled to a min/max envelope per
// column, cached per guid and evicted on reimport. Clicking the waveform
// seeks (starting playback when stopped).

import "base:runtime"
import "core:fmt"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/inspector"
import engine "moonhug:engine"
import audio "moonhug:packages/audio"

// order=1 runs after editor_init (order=0), which creates the registry maps.
@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
audio_editor_install :: proc() {
	inspector.mapAssetPreview[".mp3"] = _draw_audio_preview
	inspector.mapAssetPreview[".wav"] = _draw_audio_preview
	inspector.mapAssetPreview[".ogg"] = _draw_audio_preview
	engine.asset_pipeline_add_reimport_hook(_wave_evict)
}

// --- Waveform cache ----------------------------------------------------------

_WAVE_COLUMNS :: 512

_Waveform :: struct {
	mins, maxs: []f32, // per-column envelope, all channels merged
	frames:     i64,
	rate:       i32,
}

_wave_cache: map[engine.Asset_GUID]_Waveform

_wave_evict :: proc(guid: engine.Asset_GUID) {
	if wf, ok := _wave_cache[guid]; ok {
		// The envelope slices live on the default heap (_waveform_get) — the
		// hook fires under the reimport caller's allocator.
		delete(wf.mins, runtime.default_allocator())
		delete(wf.maxs, runtime.default_allocator())
		delete_key(&_wave_cache, guid)
	}
}

_waveform_get :: proc(guid: engine.Asset_GUID) -> (_Waveform, bool) {
	if wf, ok := _wave_cache[guid]; ok do return wf, true

	path, pok := engine.asset_pipeline_artifact_path(guid)
	if !pok do return {}, false
	pcm, spec, dok := audio.decode_file_f32(path, context.temp_allocator)
	if !dok || len(pcm) == 0 do return {}, false

	// Package-global state never borrows the caller's allocator.
	context.allocator = runtime.default_allocator()
	if _wave_cache == nil do _wave_cache = make(map[engine.Asset_GUID]_Waveform)

	channels := max(int(spec.channels), 1)
	frames := len(pcm) / channels
	wf := _Waveform{
		mins   = make([]f32, _WAVE_COLUMNS),
		maxs   = make([]f32, _WAVE_COLUMNS),
		frames = i64(frames),
		rate   = i32(spec.freq),
	}
	for col in 0 ..< _WAVE_COLUMNS {
		lo := col * frames / _WAVE_COLUMNS
		hi := max((col + 1) * frames / _WAVE_COLUMNS, lo + 1)
		mn, mx: f32
		for f in lo ..< min(hi, frames) {
			for c in 0 ..< channels {
				s := pcm[f * channels + c]
				if s < mn do mn = s
				if s > mx do mx = s
			}
		}
		wf.mins[col] = mn
		wf.maxs[col] = mx
	}
	_wave_cache[guid] = wf
	return wf, true
}

// --- Pane --------------------------------------------------------------------

_draw_audio_preview :: proc(path: string) {
	raw_guid, gok := engine.asset_db_get_guid(path)
	if !gok do return
	guid := engine.Asset_GUID(raw_guid)

	playing := audio.preview_playing(guid)
	if playing {
		if im.Button("Stop") do audio.preview_stop()
	} else if im.Button("Play") {
		audio.preview_play(guid)
	}

	wf, wok := _waveform_get(guid)
	if !wok do return

	im.SameLine()
	pos_s := playing ? f64(audio.preview_position()) / f64(wf.rate) : 0
	im.Text(fmt.ctprintf("%.2f / %.2f s", pos_s, f64(wf.frames) / f64(wf.rate)))

	avail := im.GetContentRegionAvail()
	if avail.y < 16 do return
	im.InvisibleButton("##waveform", avail)
	r_min := im.GetItemRectMin()
	r_max := im.GetItemRectMax()
	w := r_max.x - r_min.x
	mid := (r_min.y + r_max.y) * 0.5
	half := (r_max.y - r_min.y) * 0.5

	dl := im.GetWindowDrawList()
	im.DrawList_AddRectFilled(dl, r_min, r_max, im.GetColorU32ImVec4(im.Vec4{0.1, 0.1, 0.1, 1}))
	wave_col := im.GetColorU32ImVec4(im.Vec4{0.55, 0.75, 0.4, 1})
	for col in 0 ..< _WAVE_COLUMNS {
		x := r_min.x + w * f32(col) / _WAVE_COLUMNS
		im.DrawList_AddLine(dl,
			im.Vec2{x, mid - wf.maxs[col] * half},
			im.Vec2{x, mid - wf.mins[col] * half},
			wave_col, 1)
	}
	if playing && wf.frames > 0 {
		px := r_min.x + w * f32(f64(audio.preview_position()) / f64(wf.frames))
		im.DrawList_AddLine(dl, im.Vec2{px, r_min.y}, im.Vec2{px, r_max.y},
			im.GetColorU32ImVec4(im.Vec4{1, 1, 1, 0.8}), 1)
	}

	// Click to seek while playing. A stopped preview stays stopped.
	if playing && im.IsItemClicked() && w > 0 {
		frac := clamp((im.GetMousePos().x - r_min.x) / w, 0, 1)
		audio.preview_seek(i64(f64(frac) * f64(wf.frames)))
	}
}
