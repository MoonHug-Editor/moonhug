package engine

World :: struct {
	cameras: Pool(Camera),
	lifetimes: Pool(Lifetime),
	players: Pool(Player),
	scripts: Pool(Script),
	sprite_renderers: Pool(SpriteRenderer),
	tween_unions: Pool(TweenUnion),
	transforms: Pool(Transform),
	pool_table: [TypeKey]Pool_Entry,
}

w_init :: proc(w:^World)
{
	pool_init(&w.cameras)
	pool_init(&w.lifetimes)
	pool_init(&w.players)
	pool_init(&w.scripts)
	pool_init(&w.sprite_renderers)
	pool_init(&w.tween_unions)
	pool_init(&w.transforms)
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
	w.pool_table[TypeKey.TweenUnion] = pool_make_entry(&w.tween_unions)
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
		if world_pool_valid(w, c.handle) do world_pool_destroy(w, c.handle)
		c.handle.type_key = INVALID_TYPE_KEY
	}
	clear(&t.components)
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
	when T == TweenUnion {
		return pool_get(&w.tween_unions, handle)
	}
	return nil
}
