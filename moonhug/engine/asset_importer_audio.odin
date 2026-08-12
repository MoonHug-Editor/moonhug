package engine

// AudioSettings only: the audio importer lives in moonhug:packages/audio.
// The type stays here because ImportSettings is a closed union.

@(typ_guid={guid="ec017cc2-7267-45b4-ae80-d6861094d27a", makeProcName=make_pAudioSettings})
AudioSettings :: struct {
    volume: f32,
}

default_audio_settings :: proc() -> AudioSettings {
    return AudioSettings{
        volume = 1.0,
    }
}

make_pAudioSettings :: proc() -> any{
    p := new(AudioSettings)
    p.volume = 1.0
    return p^
}
