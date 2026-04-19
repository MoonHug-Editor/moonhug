package engine

World :: struct {
	cameras: Pool(Camera, 32),
	lifetimes: Pool(Lifetime),
	nested_scenes: Pool(NestedScene),
	players: Pool(Player, 10),
	scripts: Pool(Script),
	sprite_renderers: Pool(SpriteRenderer),
	transforms: Pool(Transform),
	tween_unions: Pool(TweenUnion),
	pool_table: [TypeKey]Pool_Entry,
}

w_init :: proc(w:^World)
{
	pool_init(&w.cameras)
	pool_init(&w.lifetimes)
	pool_init(&w.nested_scenes)
	pool_init(&w.players)
	pool_init(&w.scripts)
	pool_init(&w.sprite_renderers)
	pool_init(&w.transforms)
	pool_init(&w.tween_unions)
	__type_resets_init()
	__type_cleanups_init()
	__component_on_validates_init()
	__component_on_destroys_init()
	w.pool_table[TypeKey.Camera] = pool_make_entry(&w.cameras)
	w.pool_table[TypeKey.Camera].collect_fn = proc(comp: rawptr, sf: rawptr) {
		c := cast(^Camera)comp
		s := cast(^SceneFile)sf
		c_copy := c^
		c_copy.owner = {}
		append(&s.cameras, c_copy)
	}
	w.pool_table[TypeKey.Lifetime] = pool_make_entry(&w.lifetimes)
	w.pool_table[TypeKey.Lifetime].collect_fn = proc(comp: rawptr, sf: rawptr) {
		c := cast(^Lifetime)comp
		s := cast(^SceneFile)sf
		c_copy := c^
		c_copy.owner = {}
		append(&s.lifetimes, c_copy)
	}
	w.pool_table[TypeKey.NestedScene] = pool_make_entry(&w.nested_scenes)
	w.pool_table[TypeKey.NestedScene].collect_fn = proc(comp: rawptr, sf: rawptr) {
		c := cast(^NestedScene)comp
		s := cast(^SceneFile)sf
		c_copy := c^
		c_copy.owner = {}
		append(&s.nested_scenes, c_copy)
	}
	w.pool_table[TypeKey.Player] = pool_make_entry(&w.players)
	w.pool_table[TypeKey.Player].collect_fn = proc(comp: rawptr, sf: rawptr) {
		c := cast(^Player)comp
		s := cast(^SceneFile)sf
		c_copy := c^
		c_copy.owner = {}
		append(&s.players, c_copy)
	}
	w.pool_table[TypeKey.Script] = pool_make_entry(&w.scripts)
	w.pool_table[TypeKey.Script].collect_fn = proc(comp: rawptr, sf: rawptr) {
		c := cast(^Script)comp
		s := cast(^SceneFile)sf
		c_copy := c^
		c_copy.owner = {}
		append(&s.scripts, c_copy)
	}
	w.pool_table[TypeKey.SpriteRenderer] = pool_make_entry(&w.sprite_renderers)
	w.pool_table[TypeKey.SpriteRenderer].collect_fn = proc(comp: rawptr, sf: rawptr) {
		c := cast(^SpriteRenderer)comp
		s := cast(^SceneFile)sf
		c_copy := c^
		c_copy.owner = {}
		append(&s.sprite_renderers, c_copy)
	}
	w.pool_table[TypeKey.Transform] = pool_make_entry(&w.transforms)
	w.pool_table[TypeKey.TweenUnion] = pool_make_entry(&w.tween_unions)
}

__component_on_validates_init :: proc() {
	component_on_validate_procs[.Lifetime] = proc(ptr: rawptr) { on_validate_Lifetime(cast(^Lifetime)ptr) }
	component_on_validate_procs[.NestedScene] = proc(ptr: rawptr) { on_validate_NestedScene(cast(^NestedScene)ptr) }
}

__component_on_destroys_init :: proc() {
	component_on_destroy_procs[.Player] = proc(ptr: rawptr) { on_destroy_Player(cast(^Player)ptr) }
}

transform_find_comp :: proc(t: ^Transform, key: TypeKey) -> (Owned, int) {
	for c, i in t.components {
		if c.handle.type_key == key do return c, i
	}
	return {}, -1
}

transform_get_comp :: proc(tH: Transform_Handle, $T: typeid) -> (Owned, ^T) {
	w := ctx_world()
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil do return {}, nil
	when T == Camera {
		owned, _ := transform_find_comp(t, .Camera)
		if owned.handle.type_key == INVALID_TYPE_KEY do return owned, nil
		return owned, pool_get(&w.cameras, owned.handle)
	}
	else when T == Lifetime {
		owned, _ := transform_find_comp(t, .Lifetime)
		if owned.handle.type_key == INVALID_TYPE_KEY do return owned, nil
		return owned, pool_get(&w.lifetimes, owned.handle)
	}
	else when T == NestedScene {
		owned, _ := transform_find_comp(t, .NestedScene)
		if owned.handle.type_key == INVALID_TYPE_KEY do return owned, nil
		return owned, pool_get(&w.nested_scenes, owned.handle)
	}
	else when T == Player {
		owned, _ := transform_find_comp(t, .Player)
		if owned.handle.type_key == INVALID_TYPE_KEY do return owned, nil
		return owned, pool_get(&w.players, owned.handle)
	}
	else when T == Script {
		owned, _ := transform_find_comp(t, .Script)
		if owned.handle.type_key == INVALID_TYPE_KEY do return owned, nil
		return owned, pool_get(&w.scripts, owned.handle)
	}
	else when T == SpriteRenderer {
		owned, _ := transform_find_comp(t, .SpriteRenderer)
		if owned.handle.type_key == INVALID_TYPE_KEY do return owned, nil
		return owned, pool_get(&w.sprite_renderers, owned.handle)
	}
	return {}, nil
}

transform_destroy_components :: proc(tH: Transform_Handle) {
	w := ctx_world()
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil do return
	for &c in t.components {
		if c.handle.type_key == INVALID_TYPE_KEY do continue
		if world_pool_valid(w, c.handle) {
			ptr := world_pool_get(w, c.handle)
			if ptr != nil do component_on_destroy(c.handle.type_key, ptr)
			world_pool_destroy(w, c.handle)
		}
		c.handle.type_key = INVALID_TYPE_KEY
	}
	delete(t.components)
	t.components = {}
}

transform_destroy_comp :: proc(tH: Transform_Handle, $T: typeid) {
	w := ctx_world()
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil do return
	when T == Camera {
		owned, idx := transform_find_comp(t, .Camera)
		if idx < 0 do return
		pool_destroy(&w.cameras, owned.handle)
		ordered_remove(&t.components, idx)
	}
	else when T == Lifetime {
		owned, idx := transform_find_comp(t, .Lifetime)
		if idx < 0 do return
		pool_destroy(&w.lifetimes, owned.handle)
		ordered_remove(&t.components, idx)
	}
	else when T == NestedScene {
		owned, idx := transform_find_comp(t, .NestedScene)
		if idx < 0 do return
		pool_destroy(&w.nested_scenes, owned.handle)
		ordered_remove(&t.components, idx)
	}
	else when T == Player {
		owned, idx := transform_find_comp(t, .Player)
		if idx < 0 do return
		pool_destroy(&w.players, owned.handle)
		ordered_remove(&t.components, idx)
	}
	else when T == Script {
		owned, idx := transform_find_comp(t, .Script)
		if idx < 0 do return
		pool_destroy(&w.scripts, owned.handle)
		ordered_remove(&t.components, idx)
	}
	else when T == SpriteRenderer {
		owned, idx := transform_find_comp(t, .SpriteRenderer)
		if idx < 0 do return
		pool_destroy(&w.sprite_renderers, owned.handle)
		ordered_remove(&t.components, idx)
	}
}

world_pool_get_typed :: proc(w: ^World, handle: Handle, $T: typeid) -> ^T {
	when T == Transform {
		return pool_get(&w.transforms, handle)
	}
	else when T == TweenUnion {
		return pool_get(&w.tween_unions, handle)
	}
	return nil
}

world_destroy_all :: proc(w: ^World) {
	for i in 0..<len(w.players.slots) {
		slot := &w.players.slots[i]
		if !slot.alive do continue
		on_destroy_Player(&slot.data)
	}
	for i in 0..<len(w.transforms.slots) {
		slot := &w.transforms.slots[i]
		if !slot.alive do continue
		t := &slot.data
		delete(t.name)
		delete(t.children)
		delete(t.components)
	}
}
