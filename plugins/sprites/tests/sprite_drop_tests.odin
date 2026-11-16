package sprites_tests

// A texture or a slice dropped into the scene (scene_tools.asset_drop)
// becomes an object with a SpriteRenderer drawing it.

import "core:os"
import "core:testing"
import asset_pipeline "moonhug:editor/assets"
import assets "moonhug:libs/assets"
import "moonhug:packages/engine"
import "moonhug:packages/engine/editor/scene_tools"
import sprites "moonhug:packages/sprites"
import common "moonhug:tests/common"

@(private = "file") _DIR :: "moonhug/tests/fixtures/_sprite_drop_tmp"
@(private = "file") _PNG :: _DIR + "/Dots.png"

@(private = "file")
_sprite_of :: proc(tH: engine.Transform_Handle) -> (engine.PPtr, bool) {
	_, sr := engine.transform_get_comp(tH, sprites.SpriteRenderer)
	if sr == nil do return {}, false
	return sr.sprite, true
}

@(test)
test_dropped_texture_and_slice_draw_as_sprites :: proc(t: ^testing.T) {
	defer {
		common.remove_tree(_DIR)
		common.remove_tree(engine.library_dir())
	}
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)

	os.make_directory(_DIR)
	bytes, rerr := os.read_entire_file("plugins/mhgui/assets/white.png", context.temp_allocator)
	testing.expect(t, rerr == nil, "reads the source png")
	if rerr != nil do return
	testing.expect(t, os.write_entire_file(_PNG, bytes) == nil)
	asset_pipeline.asset_pipeline_init()
	asset_pipeline.asset_pipeline_ensure_import_meta(_PNG)
	engine.asset_db_init(_DIR)
	defer engine.asset_db_shutdown()
	raw, gok := engine.asset_db_get_guid(_PNG)
	testing.expect(t, gok, "the png is an asset")
	if !gok do return
	guid := engine.Asset_GUID(raw)
	root := engine.Transform_Handle(tc.scene.root.handle)
	tex := engine.PPtr{guid = guid}

	// A texture that is not sliced: the whole texture, named after the file.
	whole := scene_tools.asset_drop(tex, root)
	sprite, ok := _sprite_of(whole)
	testing.expect(t, ok && sprite == tex, "draws the whole texture")
	testing.expect_value(t, engine.pool_get(&tc.world.transforms, engine.Handle(whole)).name, "Dots")

	// Sliced: its first slice that has an id.
	settings, sok := engine.asset_pipeline_get_settings(_PNG)
	testing.expect(t, sok, "the texture has settings")
	if !sok do return
	defer free(settings.data)
	ts := settings.(engine.TextureSettings)
	ts.sprite_mode = .Multiple
	ts.sprites = make([dynamic]engine.Sprite_Rect, context.temp_allocator)
	append(&ts.sprites, engine.Sprite_Rect{id = 0, name = "unhealed", rect = {0, 0, 1, 1}})
	append(&ts.sprites, engine.Sprite_Rect{id = 5, name = "Dot", rect = {0, 0, 2, 2}})
	testing.expect(t, asset_pipeline.asset_pipeline_save_settings(_PNG, ts))
	sliced := scene_tools.asset_drop(tex, root)
	sprite, ok = _sprite_of(sliced)
	testing.expect(t, ok && sprite == engine.PPtr{guid = guid, local_id = 5}, "draws the first slice with an id")

	// A slice: that slice, named after it.
	assets.asset_db_sub_assets_set(guid, []assets.Asset_Sub_Info{{id = 5, name = "Dot", kind = "sprite"}})
	slice_ref := engine.PPtr{guid = guid, local_id = 5}
	one := scene_tools.asset_drop(slice_ref, root)
	sprite, ok = _sprite_of(one)
	testing.expect(t, ok && sprite == slice_ref, "draws the slice")
	testing.expect_value(t, engine.pool_get(&tc.world.transforms, engine.Handle(one)).name, "Dot")
}
