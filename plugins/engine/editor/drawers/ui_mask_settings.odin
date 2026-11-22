package drawers

// The UiMask tab of the Project Settings window (plugins/engine/
// ui_mask_settings.odin): the setting's row, then a box that says what the
// chosen option does. A change compiles the project's shaders again, since
// the setting is an input of each.

import "moonhug:editor/inspector"
import "moonhug:editor/widgets"
import "moonhug:libs/log"
import engine "moonhug:packages/engine"
import "moonhug:packages/engine/editor/importers"

@(private = "file")
_applied: engine.UiMask_Shader_Clip
@(private = "file")
_applied_known: bool

@(property_drawer={type=engine.UiMask_Settings, order="middle"})
property_drawer_UiMask_Settings_inspector :: proc(ctx: ^inspector.Ctx) {
	inspector.draw(ctx)
	s := cast(^engine.UiMask_Settings)ctx.ptr
	widgets.help_box(.Info, engine.ui_mask_shader_clip_description(s.shader_clip))
	if !_applied_known {
		_applied, _applied_known = s.shader_clip, true
	}
	// Typed, undone or redone: the shaders follow the value.
	if s.shader_clip != _applied {
		_applied = s.shader_clip
		count := importers.shaders_reimport_all()
		log.infof("[UiMask] Shader clip is %v: %d shaders compiled again", s.shader_clip, count)
	}
}
