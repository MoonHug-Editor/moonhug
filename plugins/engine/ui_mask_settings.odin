package engine

// UiMask project settings: how a shader comes to clip under a UiMask. A tab
// in the editor's Project Settings window, saved to
// ProjectSettings/ui_mask.json. The shader importer reads it when it
// compiles a shader, so it is an editor-time choice: a built game ships the
// compiled shaders.

// How a fragment shader the importer compiles gets the UI clip
// (libs/gfx/shaders/ui_clip.glsl).
UiMask_Shader_Clip :: enum u8 {
	// The importer adds the clip to every fragment shader it compiles. A
	// ui_clip() call written by hand is 1, so the clip applies once.
	Auto_Inject,
	// A shader clips where it includes ui_clip.glsl and calls ui_clip()
	// itself. A shader that does not draws whole under a mask.
	Manual_Include,
}

UiMask_Settings :: struct {
	shader_clip: UiMask_Shader_Clip,
}

@(project_settings={name="UiMask"})
ui_mask_settings: UiMask_Settings

@(private = "file")
_ui_mask_settings_loaded: bool

// The setting, loaded from its file on the first call.
ui_mask_shader_clip :: proc() -> UiMask_Shader_Clip {
	if !_ui_mask_settings_loaded {
		_ui_mask_settings_loaded = true
		project_settings_load("UiMask", &ui_mask_settings)
	}
	return ui_mask_settings.shader_clip
}

// What each choice does, for the settings tab.
ui_mask_shader_clip_description :: proc(mode: UiMask_Shader_Clip) -> string {
	switch mode {
	case .Auto_Inject:
		return "Every shader clips under a UiMask with nothing written in it. The importer adds the clip to each fragment shader it compiles, after the shader's own code, on the alpha of its output. A shader that includes ui_clip.glsl and calls ui_clip() itself still compiles: the call is 1 here, so the clip applies once."
	case .Manual_Include:
		return "A shader clips under a UiMask only when it says so: #include \"ui_clip.glsl\", then multiply the output's alpha by ui_clip() where the clip belongs. Nothing is added to a shader. A material whose shader does not do this draws whole under a mask, and the Console names it once."
	}
	return ""
}
