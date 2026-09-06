package text

// Registration: Text joins the engine's canvas collector as a graphic type
// (engine.canvas_graphic_register), so text and images interleave in
// hierarchy order without either package knowing the other. The stb backend
// installs here too; a replacement package sets its own at a later order.

import "base:runtime"
import "moonhug:engine"

// ImportersInit is the asset-layer init phase both binaries run.
@(phase={key=ImportersInit, order=2})
text_package_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	context.allocator = runtime.default_allocator()
	_stb_faces = make(map[engine.Asset_GUID]_Stb_Face)
	_stb_atlases = make(map[_Stb_Key]_Stb_Atlas)
	backend_set(stb_backend())
	engine.canvas_graphic_register(engine.Graphic_Desc{
		key            = .Text,
		graphic_offset = offset_of(Text, graphic),
		populate       = populate_text,
	})
}
