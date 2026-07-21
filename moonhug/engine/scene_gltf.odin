package engine

// glTF → .scene extraction, used by the editor's "Assets/Extract Assets"
// (asset_extract_gltf.odin) — the Unity model-prefab analog: a scene asset
// whose transform hierarchy mirrors the glTF nodes (names + local TRS), so
// extracted AnimationClip target paths resolve. The ROOT carries
// MeshFilter/MeshRenderer for the whole model (the mesh importer bakes all
// nodes into one blob — see docs/Meshes.md) and an Animation component when a
// clip guid is provided. Lives in the engine next to the mesh importer's
// cgltf use so it's testable without the editor.

import cgltf "vendor:cgltf"
import "core:fmt"

// Transform name for a glTF node. Unnamed nodes get "node_<index>" so
// sibling placeholders stay unique — animation channel paths
// (animation_clip_from_gltf) and the extracted scene hierarchy
// (scene_from_gltf) must produce IDENTICAL names or clips won't resolve.
gltf_node_name :: proc(data: ^cgltf.data, node: ^cgltf.node) -> string {
	if node.name != nil && len(string(node.name)) > 0 do return string(node.name)
	return fmt.tprintf("node_%d", cgltf.node_index(data, node))
}

// glTF materials in the mesh importer's SUBMESH order: first appearance
// across triangle primitives, data.nodes file order (asset_importer_mesh
// buckets the same way). Index into the result = submesh index; nil = the
// "no material" bucket.
gltf_submesh_materials :: proc(data: ^cgltf.data, alloc := context.temp_allocator) -> [dynamic]^cgltf.material {
	order := make([dynamic]^cgltf.material, alloc)
	for &node in data.nodes {
		if node.mesh == nil do continue
		for &prim in node.mesh.primitives {
			if prim.type != .triangles do continue
			found := false
			for m in order {
				if m == prim.material {
					found = true
					break
				}
			}
			if !found do append(&order, prim.material)
		}
	}
	return order
}

// Author a .scene at out_path: root named `name` with the model components,
// children mirroring the glTF node tree. `materials` assigns
// MeshRenderer.materials in submesh order (empty guids stay white); empty
// mesh/clip guids skip their component. The scene is built in a TEMPORARY
// active scene and torn down after saving — the caller's active scene and
// selection are untouched.
scene_from_gltf :: proc(data: ^cgltf.data, name: string, mesh_guid: Asset_GUID, materials: []Asset_GUID, clip: Asset_GUID, out_path: string) -> bool {
	prev := sm_scene_get_active()
	s := scene_new()
	sm_scene_set_active(s)
	// LIFO: unload (destroys the temp transforms, active → -1), then restore.
	defer sm_scene_set_active(prev)
	defer sm_scene_unload(s)

	root := transform_new(name)
	scene_set_root(s, root)

	if mesh_guid != {} {
		_, mf_raw := transform_add_comp(root, .MeshFilter)
		(cast(^MeshFilter)mf_raw).mesh = mesh_guid
		_, mr_raw := transform_add_comp(root, .MeshRenderer)
		mr := cast(^MeshRenderer)mr_raw
		for m in materials do append(&mr.materials, m)
	}
	if clip != {} {
		_, a_raw := transform_add_comp(root, .Animation)
		(cast(^Animation)a_raw).clip = clip
	}

	for &node in data.nodes {
		if node.parent == nil do _scene_gltf_add_node(data, &node, root)
	}
	return scene_save(s, out_path)
}

// One transform per glTF node, recursing into children. Names come from
// gltf_node_name — the same rule as animation channel targets, so clips
// resolve. Matrix-transform nodes (has_matrix, no TRS) keep identity —
// authoring tools overwhelmingly export TRS.
_scene_gltf_add_node :: proc(data: ^cgltf.data, node: ^cgltf.node, parent: Transform_Handle) {
	tH := transform_new(gltf_node_name(data, node), parent)
	w := ctx_world()
	t := pool_get(&w.transforms, Handle(tH))
	if node.has_translation do t.position = node.translation
	if node.has_rotation do t.rotation = node.rotation
	if node.has_scale do t.scale = node.scale
	for child in node.children {
		_scene_gltf_add_node(data, child, tH)
	}
}
