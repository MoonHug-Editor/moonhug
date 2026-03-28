package tests

import "../engine"

import "core:testing"
import "core:os"

@(test)
test_transform_new :: proc(t: ^testing.T) {
    tc_mem := new(TestCtx)
    defer free(tc_mem)
    setup(tc_mem, "test_scene")
    context.user_ptr = &tc_mem.uc
    defer teardown(tc_mem)

    tH := engine.transform_new("TestNode")
    tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
    testing.expect(t, tr != nil, "transform should exist in pool")
    if tr == nil do return

    testing.expect_value(t, tr.name, "TestNode")
    testing.expect_value(t, tr.is_active, true)
    testing.expect_value(t, tr.scale, [3]f32{1, 1, 1})
    testing.expect_value(t, tr.position, [3]f32{0, 0, 0})
    testing.expect(t, tr.local_id != 0, "should have a local_id assigned")
}

@(test)
test_transform_new_with_parent :: proc(t: ^testing.T) {
    tc_mem := new(TestCtx)
    defer free(tc_mem)
    setup(tc_mem, "test_scene")
    context.user_ptr = &tc_mem.uc
    defer teardown(tc_mem)

    parentH := engine.transform_new("Parent")
    childH := engine.transform_new("Child", parentH)

    root := engine.pool_get(&tc_mem.world.transforms, tc_mem.scene.root.handle)
    testing.expect(t, root != nil, "root should exist")

    parent := engine.pool_get(&tc_mem.world.transforms, engine.Handle(parentH))
    testing.expect(t, parent != nil, "parent should exist")

    child := engine.pool_get(&tc_mem.world.transforms, engine.Handle(childH))
    testing.expect(t, child != nil, "child should exist")

    if root == nil || parent == nil || child == nil do return

    testing.expect_value(t, len(root.children), 1)
    testing.expect_value(t, len(parent.children), 1)
    testing.expect_value(t, root.children[0].handle, engine.Handle(parentH))
    testing.expect_value(t, parent.children[0].handle, engine.Handle(childH))
    testing.expect_value(t, child.parent.handle, engine.Handle(parentH))
}

@(test)
test_transform_destroy :: proc(t: ^testing.T) {
    tc_mem := new(TestCtx)
    defer free(tc_mem)
    setup(tc_mem, "test_scene")
    context.user_ptr = &tc_mem.uc
    defer teardown(tc_mem)

    parentH := engine.transform_new("Parent")
    childH := engine.transform_new("Child", parentH)
    engine.scene_set_root(tc_mem.scene, parentH)

    engine.transform_destroy(parentH)

    testing.expect(t, !engine.pool_valid(&tc_mem.world.transforms, engine.Handle(parentH)), "parent should be destroyed")
    testing.expect(t, !engine.pool_valid(&tc_mem.world.transforms, engine.Handle(childH)), "child should be destroyed recursively")
}

@(test)
test_transform_set_parent :: proc(t: ^testing.T) {
    tc_mem := new(TestCtx)
    defer free(tc_mem)
    setup(tc_mem, "test_scene")
    context.user_ptr = &tc_mem.uc
    defer teardown(tc_mem)

    aH := engine.transform_new("A")
    bH := engine.transform_new("B")
    engine.scene_set_root(tc_mem.scene, aH)

    engine.transform_set_parent(bH, aH)

    a := engine.pool_get(&tc_mem.world.transforms, engine.Handle(aH))
    b := engine.pool_get(&tc_mem.world.transforms, engine.Handle(bH))
    testing.expect(t, a != nil && b != nil, "both should exist")
    if a == nil || b == nil do return

    testing.expect_value(t, len(a.children), 1)
    testing.expect_value(t, a.children[0].handle, engine.Handle(bH))
    testing.expect_value(t, b.parent.handle, engine.Handle(aH))
}

@(test)
test_transform_unlink_from_parent :: proc(t: ^testing.T) {
    tc_mem := new(TestCtx)
    defer free(tc_mem)
    setup(tc_mem, "test_scene")
    context.user_ptr = &tc_mem.uc
    defer teardown(tc_mem)

    parentH := engine.transform_new("Parent")
    childH := engine.transform_new("Child", parentH)

    engine.transform_unlink_from_parent(childH)

    parent := engine.pool_get(&tc_mem.world.transforms, engine.Handle(parentH))
    child := engine.pool_get(&tc_mem.world.transforms, engine.Handle(childH))
    testing.expect(t, parent != nil && child != nil, "both should exist")
    if parent == nil || child == nil do return

    testing.expect_value(t, len(parent.children), 0)
    testing.expect_value(t, child.parent.handle, engine.Handle{})
}

@(test)
test_transform_add_comp :: proc(t: ^testing.T) {
    tc_mem := new(TestCtx)
    defer free(tc_mem)
    setup(tc_mem, "test_scene")
    context.user_ptr = &tc_mem.uc
    defer teardown(tc_mem)

    tH := engine.transform_new("WithSpriteRenderer")
    owned, ptr := engine.transform_add_comp(tH, .SpriteRenderer)
    testing.expect(t, ptr != nil, "component pointer should be non-nil")
    testing.expect(t, owned.handle.type_key == .SpriteRenderer, "owned type_key should be SpriteRenderer")

    tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
    testing.expect(t, tr != nil, "transform should exist")
    if tr == nil do return
    testing.expect_value(t, len(tr.components), 1)
    testing.expect(t, tr.components[0].handle.type_key == .SpriteRenderer, "component should be SpriteRenderer")
}

@(test)
test_transform_remove_comp :: proc(t: ^testing.T) {
    tc_mem := new(TestCtx)
    defer free(tc_mem)
    setup(tc_mem, "test_scene")
    context.user_ptr = &tc_mem.uc
    defer teardown(tc_mem)

    tH := engine.transform_new("WithSpriteRenderer")
    owned, _ := engine.transform_add_comp(tH, .SpriteRenderer)

    engine.transform_remove_comp(tH, owned.handle)

    tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
    testing.expect(t, tr != nil, "transform should exist")
    if tr == nil do return
    testing.expect_value(t, len(tr.components), 0)
}

@(test)
test_transform_get_comp :: proc(t: ^testing.T) {
    tc_mem := new(TestCtx)
    defer free(tc_mem)
    setup(tc_mem, "test_scene")
    context.user_ptr = &tc_mem.uc
    defer teardown(tc_mem)

    tH := engine.transform_new("WithSpriteRenderer")
    engine.transform_add_comp(tH, .SpriteRenderer)

    owned, spriteRenderer := engine.transform_get_comp(tH, engine.SpriteRenderer)
    testing.expect(t, spriteRenderer != nil, "should find SpriteRenderer component")
    testing.expect(t, owned.handle.type_key == .SpriteRenderer, "owned type_key should be SpriteRenderer")

    _, script := engine.transform_get_comp(tH, engine.Script)
    testing.expect(t, script == nil, "should not find Script component")
}

@(test)
test_transform_get_or_add_comp :: proc(t: ^testing.T) {
    tc_mem := new(TestCtx)
    defer free(tc_mem)
    setup(tc_mem, "test_scene")
    context.user_ptr = &tc_mem.uc
    defer teardown(tc_mem)

    tH := engine.transform_new("Node")

    _, spriteRenderer1 := engine.transform_get_or_add_comp(tH, engine.SpriteRenderer)
    testing.expect(t, spriteRenderer1 != nil, "should create SpriteRenderer")

    _, spriteRenderer2 := engine.transform_get_or_add_comp(tH, engine.SpriteRenderer)
    testing.expect(t, spriteRenderer2 != nil, "should return existing SpriteRenderer")
    testing.expect(t, spriteRenderer1 == spriteRenderer2, "should return same pointer")

    tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
    testing.expect(t, tr != nil, "transform should exist")
    if tr == nil do return
    testing.expect_value(t, len(tr.components), 1)
}

@(test)
test_transform_destroy_comp :: proc(t: ^testing.T) {
    tc_mem := new(TestCtx)
    defer free(tc_mem)
    setup(tc_mem, "test_scene")
    context.user_ptr = &tc_mem.uc
    defer teardown(tc_mem)

    tH := engine.transform_new("Node")
    engine.transform_add_comp(tH, .SpriteRenderer)

    engine.transform_destroy_comp(tH, engine.SpriteRenderer)

    tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
    testing.expect(t, tr != nil, "transform should exist")
    if tr == nil do return
    testing.expect_value(t, len(tr.components), 0)
}

@(test)
test_transform_active_in_hierarchy :: proc(t: ^testing.T) {
    tc_mem := new(TestCtx)
    defer free(tc_mem)
    setup(tc_mem, "test_scene")
    context.user_ptr = &tc_mem.uc
    defer teardown(tc_mem)

    parentH := engine.transform_new("Parent")
    childH := engine.transform_new("Child", parentH)

    testing.expect(t, engine.transform_active_in_hierarchy(childH), "child should be active")

    parent := engine.pool_get(&tc_mem.world.transforms, engine.Handle(parentH))
    parent.is_active = false
    testing.expect(t, !engine.transform_active_in_hierarchy(childH), "child should be inactive when parent is inactive")
}

@(test)
test_transform_get_sibling_index :: proc(t: ^testing.T) {
    tc_mem := new(TestCtx)
    defer free(tc_mem)
    setup(tc_mem, "test_scene")
    context.user_ptr = &tc_mem.uc
    defer teardown(tc_mem)

    parentH := engine.transform_new("Parent")
    c0 := engine.transform_new("C0", parentH)
    c1 := engine.transform_new("C1", parentH)
    c2 := engine.transform_new("C2", parentH)

    testing.expect_value(t, engine.transform_get_sibling_index(c0), 0)
    testing.expect_value(t, engine.transform_get_sibling_index(c1), 1)
    testing.expect_value(t, engine.transform_get_sibling_index(c2), 2)
}
