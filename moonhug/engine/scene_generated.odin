package engine

@(typ_guid={guid = "0d489fce-9c04-4e4d-be12-f3f590d60cea"})
SceneFile :: struct {
	root:          Local_ID,
	next_local_id: Local_ID,
	transforms:    [dynamic]Transform,
	cameras: [dynamic]Camera,
	players: [dynamic]Player,
	scripts: [dynamic]Script,
	sprite_renderers: [dynamic]SpriteRenderer,
}

_scene_load_as_child :: proc(sf: ^SceneFile, parent: Transform_Handle = {}, s: ^Scene = nil) -> Transform_Handle {
	w := ctx_world()

	id_to_transform_handle := make(map[Local_ID]Handle, context.temp_allocator)
	id_to_camera_handle := make(map[Local_ID]Handle, context.temp_allocator)
	id_to_player_handle := make(map[Local_ID]Handle, context.temp_allocator)
	id_to_script_handle := make(map[Local_ID]Handle, context.temp_allocator)
	id_to_sprite_renderer_handle := make(map[Local_ID]Handle, context.temp_allocator)

	for &camera_data in sf.cameras {
		handle, camera := pool_create(&w.cameras)
		handle.type_key = .Camera
		camera^ = camera_data
		id_to_camera_handle[camera_data.local_id] = handle
	}

	for &player_data in sf.players {
		handle, player := pool_create(&w.players)
		handle.type_key = .Player
		player^ = player_data
		id_to_player_handle[player_data.local_id] = handle
	}

	for &script_data in sf.scripts {
		handle, script := pool_create(&w.scripts)
		handle.type_key = .Script
		script^ = script_data
		id_to_script_handle[script_data.local_id] = handle
	}

	for &sprite_renderer_data in sf.sprite_renderers {
		handle, sprite_renderer := pool_create(&w.sprite_renderers)
		handle.type_key = .SpriteRenderer
		sprite_renderer^ = sprite_renderer_data
		id_to_sprite_renderer_handle[sprite_renderer_data.local_id] = handle
	}

	for &t_data in sf.transforms {
		handle, t := pool_create(&w.transforms)
		t^ = t_data
		t.scene = s
		if t.rotation == {0, 0, 0, 0} do t.rotation = QUAT_IDENTITY
		t_data.children = {}
		t_data.components = {}
		id_to_transform_handle[t_data.local_id] = handle
	}

	for _, handle in id_to_transform_handle {
		t := pool_get(&w.transforms, handle)
		if t == nil do continue

		if h, ok := resolve_handle(t.parent.pptr.local_id, id_to_transform_handle); ok {
			t.parent.handle = h
		}

		for &child in t.children {
			if h, ok := resolve_handle(child.pptr.local_id, id_to_transform_handle); ok {
				child.handle = h
			}
		}

		for &c in t.components {
			if h, ok := resolve_handle(c.local_id, id_to_camera_handle); ok {
				c.handle = h
				camera := pool_get(&w.cameras, h)
				if camera != nil do camera.owner = Transform_Handle(handle)
			} else if h, ok := resolve_handle(c.local_id, id_to_player_handle); ok {
				c.handle = h
				player := pool_get(&w.players, h)
				if player != nil do player.owner = Transform_Handle(handle)
			} else if h, ok := resolve_handle(c.local_id, id_to_script_handle); ok {
				c.handle = h
				script := pool_get(&w.scripts, h)
				if script != nil do script.owner = Transform_Handle(handle)
			} else if h, ok := resolve_handle(c.local_id, id_to_sprite_renderer_handle); ok {
				c.handle = h
				sprite_renderer := pool_get(&w.sprite_renderers, h)
				if sprite_renderer != nil do sprite_renderer.owner = Transform_Handle(handle)
			}
		}
	}

	root_handle: Handle
	if sf.root != 0 {
		if h, ok := id_to_transform_handle[sf.root]; ok {
			root_handle = h
		}
	}

	if parent != {} && pool_valid(&w.transforms, Handle(parent)) && root_handle != {} {
		root_t := pool_get(&w.transforms, root_handle)
		if root_t != nil {
			root_t.parent = make_transform_ref(parent)
			p := pool_get(&w.transforms, Handle(parent))
			if p != nil {
				append(&p.children, Ref{ pptr=PPtr{local_id = root_t.local_id}, handle = root_handle })
			}
		}
	}

	return Transform_Handle(root_handle)
}

scene_file_destroy :: proc(sf: ^SceneFile) {
	for &t in sf.transforms {
		delete(t.children)
		delete(t.components)
	}
	delete(sf.transforms)
	delete(sf.cameras)
	delete(sf.players)
	delete(sf.scripts)
	delete(sf.sprite_renderers)
}
