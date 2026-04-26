package engine

import "core:encoding/json"
import "core:strings"

@(typ_guid={guid = "0d489fce-9c04-4e4d-be12-f3f590d60cea"})
SceneFile :: struct {
	root:          Local_ID,
	next_local_id: Local_ID,
	transforms:    [dynamic]Transform,
	nested_scenes: [dynamic]NestedScene,
	cameras: [dynamic]Camera,
	lifetimes: [dynamic]Lifetime,
	players: [dynamic]Player,
	scripts: [dynamic]Script,
	sprite_renderers: [dynamic]SpriteRenderer,
}

_scene_load_as_child :: proc(sf: ^SceneFile, parent: Transform_Handle = {}, s: ^Scene = nil) -> Transform_Handle {
	w := ctx_world()

	id_to_transform_handle := make(map[Local_ID]Handle, context.temp_allocator)
	id_to_camera_handle := make(map[Local_ID]Handle, context.temp_allocator)
	id_to_lifetime_handle := make(map[Local_ID]Handle, context.temp_allocator)
	id_to_player_handle := make(map[Local_ID]Handle, context.temp_allocator)
	id_to_script_handle := make(map[Local_ID]Handle, context.temp_allocator)
	id_to_sprite_renderer_handle := make(map[Local_ID]Handle, context.temp_allocator)

	if s != nil {
		for &ns_data in sf.nested_scenes {
			ns_copy := ns_data
			ns_copy.overrides = make([dynamic]Override, len(ns_data.overrides))
			for i in 0..<len(ns_data.overrides) {
				src := &ns_data.overrides[i]
				ns_copy.overrides[i] = Override{
					target        = src.target,
					property_path = strings.clone(src.property_path),
					value         = json.clone_value(src.value),
				}
			}
			append(&s.nested_scenes, ns_copy)
		}
	}

	for &camera_data in sf.cameras {
		handle, camera := pool_create(&w.cameras)
		handle.type_key = .Camera
		camera^ = camera_data
		id_to_camera_handle[camera_data.local_id] = handle
		camera_data = {}
	}

	for &lifetime_data in sf.lifetimes {
		handle, lifetime := pool_create(&w.lifetimes)
		handle.type_key = .Lifetime
		lifetime^ = lifetime_data
		id_to_lifetime_handle[lifetime_data.local_id] = handle
		lifetime_data = {}
	}

	for &player_data in sf.players {
		handle, player := pool_create(&w.players)
		handle.type_key = .Player
		player^ = player_data
		id_to_player_handle[player_data.local_id] = handle
		player_data = {}
	}

	for &script_data in sf.scripts {
		handle, script := pool_create(&w.scripts)
		handle.type_key = .Script
		script^ = script_data
		id_to_script_handle[script_data.local_id] = handle
		script_data = {}
	}

	for &sprite_renderer_data in sf.sprite_renderers {
		handle, sprite_renderer := pool_create(&w.sprite_renderers)
		handle.type_key = .SpriteRenderer
		sprite_renderer^ = sprite_renderer_data
		id_to_sprite_renderer_handle[sprite_renderer_data.local_id] = handle
		sprite_renderer_data = {}
	}

	for &t_data in sf.transforms {
		handle, t := pool_create(&w.transforms)
		handle.type_key = .Transform
		t^ = t_data
		t.scene = s
		if t.rotation == {0, 0, 0, 0} do t.rotation = QUAT_IDENTITY
		t_data.name = ""
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
			} else if h, ok := resolve_handle(c.local_id, id_to_lifetime_handle); ok {
				c.handle = h
				lifetime := pool_get(&w.lifetimes, h)
				if lifetime != nil do lifetime.owner = Transform_Handle(handle)
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

_scene_file_remap_local_ids :: proc(sf: ^SceneFile, s: ^Scene) {
	if s == nil do return
	remap := make(map[Local_ID]Local_ID)
	defer delete(remap)

	for &t in sf.transforms {
		new_id := scene_next_id(s)
		remap[t.local_id] = new_id
		t.local_id = new_id
	}

	for &c in sf.cameras { new_id := scene_next_id(s); remap[c.local_id] = new_id; c.local_id = new_id }
	for &c in sf.lifetimes { new_id := scene_next_id(s); remap[c.local_id] = new_id; c.local_id = new_id }
	for &c in sf.players { new_id := scene_next_id(s); remap[c.local_id] = new_id; c.local_id = new_id }
	for &c in sf.scripts { new_id := scene_next_id(s); remap[c.local_id] = new_id; c.local_id = new_id }
	for &c in sf.sprite_renderers { new_id := scene_next_id(s); remap[c.local_id] = new_id; c.local_id = new_id }
	for &ns in sf.nested_scenes { new_id := scene_next_id(s); remap[ns.local_id] = new_id; ns.local_id = new_id }

	for &t in sf.transforms {
		if t.parent.pptr.local_id != 0 {
			if new_id, ok := remap[t.parent.pptr.local_id]; ok {
				t.parent.pptr.local_id = new_id
			}
		}
		for &child in t.children {
			if new_id, ok := remap[child.pptr.local_id]; ok {
				child.pptr.local_id = new_id
			}
		}
		for &c in t.components {
			if new_id, ok := remap[c.local_id]; ok {
				c.local_id = new_id
			}
		}
	}

	for &ns in sf.nested_scenes {
		if new_id, ok := remap[ns.transform_parent]; ok {
			ns.transform_parent = new_id
		}
	}

	if new_root, ok := remap[sf.root]; ok {
		sf.root = new_root
	}

	for &c in sf.cameras { _remap_refs_in_value(&c, type_info_of(Camera), &remap) }
	for &c in sf.lifetimes { _remap_refs_in_value(&c, type_info_of(Lifetime), &remap) }
	for &c in sf.players { _remap_refs_in_value(&c, type_info_of(Player), &remap) }
	for &c in sf.scripts { _remap_refs_in_value(&c, type_info_of(Script), &remap) }
	for &c in sf.sprite_renderers { _remap_refs_in_value(&c, type_info_of(SpriteRenderer), &remap) }
}

scene_file_destroy :: proc(sf: ^SceneFile) {
	for &t in sf.transforms {
		delete(t.name)
		delete(t.children)
		delete(t.components)
	}
	delete(sf.transforms)
	for &ns in sf.nested_scenes {
		for &ov in ns.overrides {
			delete(ov.property_path)
			json.destroy_value(ov.value)
		}
		delete(ns.overrides)
	}
	delete(sf.nested_scenes)
	for &c in sf.cameras { type_cleanup(.Camera, &c) }
	delete(sf.cameras)
	for &c in sf.lifetimes { type_cleanup(.Lifetime, &c) }
	delete(sf.lifetimes)
	for &c in sf.players { type_cleanup(.Player, &c) }
	delete(sf.players)
	for &c in sf.scripts { type_cleanup(.Script, &c) }
	delete(sf.scripts)
	for &c in sf.sprite_renderers { type_cleanup(.SpriteRenderer, &c) }
	delete(sf.sprite_renderers)
}

scene_file_destroy_shallow :: proc(sf: ^SceneFile) {
	for &t in sf.transforms {
		delete(t.name)
		delete(t.children)
		delete(t.components)
	}
	delete(sf.transforms)
	delete(sf.nested_scenes)
	delete(sf.cameras)
	delete(sf.lifetimes)
	delete(sf.players)
	delete(sf.scripts)
	delete(sf.sprite_renderers)
}
