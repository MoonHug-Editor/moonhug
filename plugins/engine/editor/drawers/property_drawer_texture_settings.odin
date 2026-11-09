package drawers

// The texture importer's settings: choosing a Texture Type sets the settings
// that type expects (engine.texture_type_defaults), a Sprite's Clamp wrap
// for one. The import settings document records the frame's whole change as
// one undo step, so undoing the type also brings the old wrap back.

import "moonhug:editor/inspector"
import "moonhug:packages/engine"

@(property_drawer={type=engine.TextureSettings, order="outer"})
property_drawer_TextureSettings_type :: proc(ctx: ^inspector.Ctx) {
	ts := cast(^engine.TextureSettings)ctx.ptr
	before := ts.texture_type
	inspector.draw(ctx)
	if ts.texture_type != before do engine.texture_type_defaults(ts)
}
