package engine

import "core:encoding/json"
import "core:strings"

@(typ_guid={guid = "0d489fce-9c04-4e4d-be12-f3f590d60cea"})
SceneFile :: struct {
	root:          Local_ID,
	next_local_id: Local_ID,
	transforms:    [dynamic]Transform,
	nested_scenes: [dynamic]NestedScene,
	breadcrumbs:   [dynamic]Breadcrumb,
	components:    [dynamic]json.Value, // guid-tagged records, every component type
}

_scene_load_as_child :: proc(sf: ^SceneFile, parent: Transform_Handle = {}, s: ^Scene = nil, transform_scope_guid: Asset_GUID = {}, skip_scene_local_id_registration := false) -> Transform_Handle {
	w := ctx_world()

	id_to_transform_handle := make(map[Local_ID]Handle, context.temp_allocator)

	if s != nil {
		scene_file_remap_merge_metadata(sf, s)
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

	// Own-file loads stash unknown records on the scene; nested-prefab
	// materializations (scoped guid) never do — their file owns them.
	id_to_ext_handle := _scene_load_ext_components(sf, asset_guid_is_empty(transform_scope_guid) ? s : nil)

	for &t_data in sf.transforms {
		handle, t := pool_create(&w.transforms)
		handle.type_key = .Transform
		t^ = t_data
		t.scene = s
		if !asset_guid_is_empty(transform_scope_guid) {
			t.scene_asset_guid = transform_scope_guid
		} else if s != nil && !asset_guid_is_empty(s.asset_guid) {
			t.scene_asset_guid = s.asset_guid
		} else {
			t.scene_asset_guid = {}
		}
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
			if h, ok := resolve_handle(c.local_id, id_to_ext_handle); ok {
				c.handle = h
				_ext_set_owner(w, h, Transform_Handle(handle))
			}
		}
	}

	if s != nil {
		if !skip_scene_local_id_registration {
			for lid, h in id_to_transform_handle {
				if _, exists := bimap_get(&s.local_ids, lid); !exists {
					bimap_insert(&s.local_ids, lid, h)
				}
			}
			for lid, h in id_to_ext_handle {
				bimap_insert(&s.local_ids, lid, h)
			}
		}
		for bc in sf.breadcrumbs {
			scene_breadcrumb_put(s, bc)
		}
		_file_lookup := make(map[Local_ID]Handle, context.temp_allocator)
		for lid, h in id_to_transform_handle do _file_lookup[lid] = h
		for lid, h in id_to_ext_handle do _file_lookup[lid] = h
		for _, h in id_to_ext_handle {
			_ext_resolve_refs(w, h, s, &_file_lookup)
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

	if s != nil {
		nested_scene_ensure_host_pegs(s)
	}

	return Transform_Handle(root_handle)
}

_scene_file_remap_local_ids :: proc(sf: ^SceneFile, s: ^Scene, mapper: proc(user: rawptr, old: Local_ID) -> Local_ID = nil, user: rawptr = nil) {
	if s == nil do return
	remap := make(map[Local_ID]Local_ID)
	defer delete(remap)

	for &t in sf.transforms {
		new_id := _remap_new_id(s, mapper, user, t.local_id)
		remap[t.local_id] = new_id
		t.local_id = new_id
	}

	ext_temps := _scene_file_remap_ext_begin(sf, s, &remap, mapper, user)
	for &ns in sf.nested_scenes { new_id := _remap_new_id(s, mapper, user, ns.local_id); remap[ns.local_id] = new_id; ns.local_id = new_id }
	for &bc in sf.breadcrumbs {
		old := bc.local_id
		new_id := _remap_new_id(s, mapper, user, old)
		remap[old] = new_id
		bc.local_id = new_id
	}

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

	for &bc in sf.breadcrumbs {
		if new_id, ok := remap[bc.scene_instance]; ok {
			bc.scene_instance = new_id
		}
	}

	for &ns in sf.nested_scenes {
		if ns.host_breadcrumb_id != 0 {
			if nid, ok := remap[ns.host_breadcrumb_id]; ok {
				ns.host_breadcrumb_id = nid
			}
		}
	}
	for &bc in sf.breadcrumbs {
		if pptr_guid_is_empty(bc.scene_source.guid) {
			if nid, ok := remap[bc.scene_source.local_id]; ok {
				bc.scene_source.local_id = nid
			}
		}
	}

	if new_root, ok := remap[sf.root]; ok {
		sf.root = new_root
	}

	_scene_file_remap_ext_finish(ext_temps, &remap)
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
	delete(sf.breadcrumbs)
	_scene_file_destroy_ext(sf)
}

scene_file_destroy_shallow :: proc(sf: ^SceneFile) {
	for &t in sf.transforms {
		delete(t.name)
		delete(t.children)
		delete(t.components)
	}
	delete(sf.transforms)
	delete(sf.nested_scenes)
	delete(sf.breadcrumbs)
	_scene_file_destroy_ext(sf)
}
