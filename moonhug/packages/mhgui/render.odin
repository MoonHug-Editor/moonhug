package mhgui

// mhgui — the drawing half of UI (docs/Gui.md). The canvas tree (Canvas,
// RectTransform, CanvasRenderer, CanvasScaler, the rect walk and the canvas
// collector) is engine vocabulary (engine/ui_canvas.odin); this package owns
// graphics: Image, registered as a graphic type, and the LayoutGroup
// container.

import "core:encoding/uuid"
import "moonhug:engine"

// The package's white texture (assets/white.png, meta committed with it):
// what an Image without a sprite draws.
WHITE_TEXTURE_GUID :: "6ae7892c-14e2-4fc9-93ae-bf60599a235a"

white_texture_guid :: proc() -> engine.Asset_GUID {
	@(static) guid: engine.Asset_GUID
	if engine.asset_guid_is_empty(guid) {
		if g, err := uuid.read(WHITE_TEXTURE_GUID); err == nil do guid = engine.Asset_GUID(g)
	}
	return guid
}

// ImportersInit is the asset-layer init phase both binaries run.
@(phase={key=ImportersInit, order=2})
mhgui_package_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	engine.canvas_graphic_register(engine.Graphic_Desc{
		key            = .Image,
		graphic_offset = offset_of(Image, graphic),
		populate       = populate_image,
	})
	engine.canvas_layout_register(layout_provider)
}
