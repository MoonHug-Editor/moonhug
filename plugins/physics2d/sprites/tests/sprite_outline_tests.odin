package physics2d_sprites_tests

// The sprite outline (physics2d/sprites): a mask's boundary as a simplified
// loop, a round sprite's outline as a round polygon, and a polygon collider
// added to a sprite taking the outline for its points.

import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import "moonhug:packages/engine"
import common "moonhug:tests/common"
import asset_pipeline "moonhug:editor/assets"
import physics2d "moonhug:packages/physics2d"
import physics2d_sprites "moonhug:packages/physics2d/sprites"
import sprites "moonhug:packages/sprites"

@(private = "file")
_SRC_DIR :: "moonhug/tests/fixtures/_sprite_outline_tmp"

@(private = "file")
_copy_fixture :: proc(t: ^testing.T, name: string) -> bool {
	os.make_directory(_SRC_DIR)
	src, rerr := os.read_entire_file(strings.concatenate({"moonhug/tests/fixtures/textures/", name}, context.temp_allocator), context.temp_allocator)
	testing.expectf(t, rerr == nil, "reads the %s fixture", name)
	if rerr != nil do return false
	return os.write_entire_file(strings.concatenate({_SRC_DIR, "/", name}, context.temp_allocator), src) == nil
}

@(test)
sprite_outline_of_a_square_mask :: proc(t: ^testing.T) {
	// A 40 x 40 opaque square inside a 50 x 50 mask. The outline follows the
	// square's pixel edges (5 to 45) with each corner cut by half a pixel,
	// and the simplification keeps one point per corner, so the area is a
	// little under 1600.
	mask := make([]bool, 2500, context.temp_allocator)
	for y in 5 ..< 45 do for x in 5 ..< 45 do mask[y * 50 + x] = true
	outline := physics2d_sprites.mask_outline(mask, 50, 50, context.temp_allocator)
	testing.expectf(t, len(outline) >= 4 && len(outline) <= 8, "%d points", len(outline))
	area := abs(physics2d.polygon_area(outline))
	testing.expectf(t, area > 1560 && area <= 1600, "area %v", area)
	for p in outline {
		testing.expectf(t, p.x >= 5 && p.x <= 45 && p.y >= 5 && p.y <= 45, "a point on the square's edge, %v", p)
	}
	// Nothing opaque: no outline.
	empty := make([]bool, 100, context.temp_allocator)
	testing.expect(t, len(physics2d_sprites.mask_outline(empty, 10, 10, context.temp_allocator)) == 0)
}

@(test)
sprite_outline_of_a_round_sprite :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	if !_copy_fixture(t, "circle-256.png") do return
	defer common.remove_tree(_SRC_DIR)
	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init(_SRC_DIR)
	defer { engine.asset_db_shutdown(); common.remove_tree(engine.library_dir()) }
	guid, gok := engine.asset_db_get_guid(_SRC_DIR + "/circle-256.png")
	testing.expect(t, gok)
	if !gok do return

	points: [dynamic][2]f32
	defer delete(points)
	testing.expect(t, physics2d_sprites.sprite_outline(engine.PPtr{guid = engine.Asset_GUID(guid)}, &points), "the circle has an outline")
	testing.expectf(t, len(points) >= 12 && len(points) <= 200, "%d points", len(points))
	// Every point about as far from the center as every other: a circle,
	// centered on the sprite's center pivot, in units of 100 pixels.
	center: [2]f32
	for p in points do center += p
	center /= f32(len(points))
	testing.expectf(t, abs(center.x) < 0.05 && abs(center.y) < 0.05, "centered, %v", center)
	mean: f32
	for p in points do mean += math.sqrt((p.x - center.x) * (p.x - center.x) + (p.y - center.y) * (p.y - center.y))
	mean /= f32(len(points))
	testing.expectf(t, mean > 0.3 && mean < 1.28, "a radius under 128 px, %v", mean)
	for p in points {
		r := math.sqrt((p.x - center.x) * (p.x - center.x) + (p.y - center.y) * (p.y - center.y))
		testing.expectf(t, abs(r - mean) < mean * 0.06, "round, %v at %v", p, r)
	}
	pieces, pok := physics2d.polygon_partition(points[:], context.temp_allocator)
	testing.expect(t, pok && len(pieces) >= 2, "the outline is a simple polygon the collider can use")
}

@(test)
polygon_collider_added_to_a_sprite_takes_its_outline :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	if !_copy_fixture(t, "mickey.png") do return
	defer common.remove_tree(_SRC_DIR)
	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init(_SRC_DIR)
	defer { engine.asset_db_shutdown(); common.remove_tree(engine.library_dir()) }
	guid, gok := engine.asset_db_get_guid(_SRC_DIR + "/mickey.png")
	testing.expect(t, gok)
	if !gok do return
	testing.expect(t, physics2d.polygon_sprite_outline != nil, "the editor installed the outline")

	obj := engine.transform_new("Mickey")
	_, sr_ptr := engine.transform_add_comp(obj, .SpriteRenderer)
	(cast(^sprites.SpriteRenderer)sr_ptr).sprite = engine.PPtr{guid = engine.Asset_GUID(guid)}
	_, pc_ptr := engine.transform_add_comp(obj, .PolygonCollider2D)
	pc := cast(^physics2d.PolygonCollider2D)pc_ptr
	testing.expectf(t, len(pc.points) > 8, "the outline has %d points, not the pentagon's five", len(pc.points))
	area := abs(physics2d.polygon_area(pc.points[:]))
	// A 300 x 279 image at 100 pixels per unit: an opaque figure well inside.
	testing.expectf(t, area > 1 && area < 3 * 2.79, "area %v", area)
	pieces, pok := physics2d.polygon_partition(pc.points[:], context.temp_allocator)
	testing.expectf(t, pok, "the outline is a simple polygon")
	if pok do testing.expect(t, len(pieces) >= 2)

	// An object without a sprite gets the pentagon.
	plain := engine.transform_new("Plain")
	_, plain_ptr := engine.transform_add_comp(plain, .PolygonCollider2D)
	testing.expect_value(t, len((cast(^physics2d.PolygonCollider2D)plain_ptr).points), 5)
}
