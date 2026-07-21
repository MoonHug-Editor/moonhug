package engine

World :: struct {
	animations: Pool(Animation),
	cameras: Pool(Camera, 32),
	lifetimes: Pool(Lifetime),
	lights: Pool(Light, 8),
	mesh_filters: Pool(MeshFilter),
	mesh_renderers: Pool(MeshRenderer),
	players: Pool(Player, 10),
	scripts: Pool(Script),
	sprite_renderers: Pool(SpriteRenderer),
	sprite_sorting_groups: Pool(SpriteSortingGroup),
	transforms: Pool(Transform),
	tween_unions: Pool(TweenUnion),
	ext_pools: [TypeKey]rawptr,
	pool_table: [TypeKey]Pool_Entry,
}

w_init :: proc(w:^World)
{
	pool_init(&w.animations)
	pool_init(&w.cameras)
	pool_init(&w.lifetimes)
	pool_init(&w.lights)
	pool_init(&w.mesh_filters)
	pool_init(&w.mesh_renderers)
	pool_init(&w.players)
	pool_init(&w.scripts)
	pool_init(&w.sprite_renderers)
	pool_init(&w.sprite_sorting_groups)
	pool_init(&w.transforms)
	pool_init(&w.tween_unions)
	__type_resets_init()
	__type_cleanups_init()
	__component_on_validates_init()
	__component_on_destroys_init()
	w.pool_table[TypeKey.Animation] = pool_make_entry(&w.animations)
	w.pool_table[TypeKey.Animation].collect_fn = proc(comp: rawptr, sf: rawptr) {
		c := cast(^Animation)comp
		s := cast(^SceneFile)sf
		c_copy := c^
		c_copy.owner = {}
		append(&s.animations, c_copy)
	}
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
	w.pool_table[TypeKey.Light] = pool_make_entry(&w.lights)
	w.pool_table[TypeKey.Light].collect_fn = proc(comp: rawptr, sf: rawptr) {
		c := cast(^Light)comp
		s := cast(^SceneFile)sf
		c_copy := c^
		c_copy.owner = {}
		append(&s.lights, c_copy)
	}
	w.pool_table[TypeKey.MeshFilter] = pool_make_entry(&w.mesh_filters)
	w.pool_table[TypeKey.MeshFilter].collect_fn = proc(comp: rawptr, sf: rawptr) {
		c := cast(^MeshFilter)comp
		s := cast(^SceneFile)sf
		c_copy := c^
		c_copy.owner = {}
		append(&s.mesh_filters, c_copy)
	}
	w.pool_table[TypeKey.MeshRenderer] = pool_make_entry(&w.mesh_renderers)
	w.pool_table[TypeKey.MeshRenderer].collect_fn = proc(comp: rawptr, sf: rawptr) {
		c := cast(^MeshRenderer)comp
		s := cast(^SceneFile)sf
		c_copy := c^
		c_copy.owner = {}
		append(&s.mesh_renderers, c_copy)
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
	w.pool_table[TypeKey.SpriteSortingGroup] = pool_make_entry(&w.sprite_sorting_groups)
	w.pool_table[TypeKey.SpriteSortingGroup].collect_fn = proc(comp: rawptr, sf: rawptr) {
		c := cast(^SpriteSortingGroup)comp
		s := cast(^SceneFile)sf
		c_copy := c^
		c_copy.owner = {}
		append(&s.sprite_sorting_groups, c_copy)
	}
	w.pool_table[TypeKey.Transform] = pool_make_entry(&w.transforms)
	w.pool_table[TypeKey.TweenUnion] = pool_make_entry(&w.tween_unions)
	_w_init_ext_pools(w)
}

__component_on_validates_init :: proc() {
	component_on_validate_procs[.Lifetime] = proc(ptr: rawptr) { on_validate_Lifetime(cast(^Lifetime)ptr) }
}

__component_on_destroys_init :: proc() {
	component_on_destroy_procs[.MeshRenderer] = proc(ptr: rawptr) { on_destroy_MeshRenderer(cast(^MeshRenderer)ptr) }
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
	when T == Animation {
		owned, _ := transform_find_comp(t, .Animation)
		if owned.handle.type_key == INVALID_TYPE_KEY do return owned, nil
		return owned, pool_get(&w.animations, owned.handle)
	}
	else when T == Camera {
		owned, _ := transform_find_comp(t, .Camera)
		if owned.handle.type_key == INVALID_TYPE_KEY do return owned, nil
		return owned, pool_get(&w.cameras, owned.handle)
	}
	else when T == Lifetime {
		owned, _ := transform_find_comp(t, .Lifetime)
		if owned.handle.type_key == INVALID_TYPE_KEY do return owned, nil
		return owned, pool_get(&w.lifetimes, owned.handle)
	}
	else when T == Light {
		owned, _ := transform_find_comp(t, .Light)
		if owned.handle.type_key == INVALID_TYPE_KEY do return owned, nil
		return owned, pool_get(&w.lights, owned.handle)
	}
	else when T == MeshFilter {
		owned, _ := transform_find_comp(t, .MeshFilter)
		if owned.handle.type_key == INVALID_TYPE_KEY do return owned, nil
		return owned, pool_get(&w.mesh_filters, owned.handle)
	}
	else when T == MeshRenderer {
		owned, _ := transform_find_comp(t, .MeshRenderer)
		if owned.handle.type_key == INVALID_TYPE_KEY do return owned, nil
		return owned, pool_get(&w.mesh_renderers, owned.handle)
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
	else when T == SpriteSortingGroup {
		owned, _ := transform_find_comp(t, .SpriteSortingGroup)
		if owned.handle.type_key == INVALID_TYPE_KEY do return owned, nil
		return owned, pool_get(&w.sprite_sorting_groups, owned.handle)
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
	when T == Animation {
		owned, idx := transform_find_comp(t, .Animation)
		if idx < 0 do return
		pool_destroy(&w.animations, owned.handle)
		ordered_remove(&t.components, idx)
	}
	else when T == Camera {
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
	else when T == Light {
		owned, idx := transform_find_comp(t, .Light)
		if idx < 0 do return
		pool_destroy(&w.lights, owned.handle)
		ordered_remove(&t.components, idx)
	}
	else when T == MeshFilter {
		owned, idx := transform_find_comp(t, .MeshFilter)
		if idx < 0 do return
		pool_destroy(&w.mesh_filters, owned.handle)
		ordered_remove(&t.components, idx)
	}
	else when T == MeshRenderer {
		owned, idx := transform_find_comp(t, .MeshRenderer)
		if idx < 0 do return
		pool_destroy(&w.mesh_renderers, owned.handle)
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
	else when T == SpriteSortingGroup {
		owned, idx := transform_find_comp(t, .SpriteSortingGroup)
		if idx < 0 do return
		pool_destroy(&w.sprite_sorting_groups, owned.handle)
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
	_world_destroy_ext(w)
	for i in 0..<len(w.mesh_renderers.slots) {
		slot := &w.mesh_renderers.slots[i]
		if !slot.alive do continue
		on_destroy_MeshRenderer(&slot.data)
	}
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
