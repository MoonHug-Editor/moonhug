package engine

// glTF → .scene extraction, used by the editor's "Assets/Extract Assets"
// (asset_extract_gltf.odin) — the Unity model-prefab analog: a scene asset
// whose transform hierarchy mirrors the glTF nodes (names + local TRS), so
// extracted AnimationClip target paths resolve. Each mesh-bearing node
// carries MeshFilter (part = its glTF mesh, node-local artifact) +
// MeshRenderer (that mesh's material order), so animated node transforms
// move real geometry; the root carries the Animation component when a clip
// guid is provided. Lives in the engine next to the mesh importer's cgltf
// use so it's testable without the editor.

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

// One glTF mesh's materials in ITS submesh order: first appearance across
// its triangle primitives (asset_importer_mesh buckets a part the same way).
// Index into the result = submesh index; nil = the "no material" bucket.
gltf_mesh_materials :: proc(mesh: ^cgltf.mesh, alloc := context.temp_allocator) -> [dynamic]^cgltf.material {
	order := make([dynamic]^cgltf.material, alloc)
	for &prim in mesh.primitives {
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
	return order
}

// Author a .scene at out_path: root named `name`, children mirroring the
// glTF node tree, mesh-bearing nodes wired to their part of the model.
// `material_guids` is indexed by glTF material index (data.materials order,
// empty guids stay white); empty mesh/clip guids skip their components. The
// scene is built in a TEMPORARY active scene and torn down after saving —
// the caller's active scene and selection are untouched.
scene_from_gltf :: proc(data: ^cgltf.data, name: string, mesh_guid: Asset_GUID, material_guids: []Asset_GUID, clip: Asset_GUID, out_path: string) -> bool {
	prev := sm_scene_get_active()
	s := scene_new()
	sm_scene_set_active(s)
	// LIFO: unload (destroys the temp transforms, active → -1), then restore.
	defer sm_scene_set_active(prev)
	defer sm_scene_unload(s)

	root := transform_new(name)
	scene_set_root(s, root)

	if clip != {} {
		_, a_raw := transform_add_comp(root, .Animation)
		(cast(^Animation)a_raw).clip = clip
	}

	for &node in data.nodes {
		if node.parent == nil do _scene_gltf_add_node(data, &node, root, mesh_guid, material_guids)
	}
	return scene_save(s, out_path)
}

// One transform per glTF node, recursing into children. Names come from
// gltf_node_name — the same rule as animation channel targets, so clips
// resolve. Matrix-transform nodes (has_matrix, no TRS) keep identity —
// authoring tools overwhelmingly export TRS. Mesh nodes get
// MeshFilter{part = mesh index + 1} + MeshRenderer{materials in the mesh's
// own submesh order}.
_scene_gltf_add_node :: proc(data: ^cgltf.data, node: ^cgltf.node, parent: Transform_Handle, mesh_guid: Asset_GUID, material_guids: []Asset_GUID) {
	tH := transform_new(gltf_node_name(data, node), parent)
	w := ctx_world()
	t := pool_get(&w.transforms, Handle(tH))
	if node.has_translation do t.position = node.translation
	if node.has_rotation do t.rotation = node.rotation
	if node.has_scale do t.scale = node.scale

	if node.mesh != nil && mesh_guid != {} {
		_, mf_raw := transform_add_comp(tH, .MeshFilter)
		mf := cast(^MeshFilter)mf_raw
		mf.mesh = mesh_guid
		mf.part = i32(cgltf.mesh_index(data, node.mesh)) + 1
		_, mr_raw := transform_add_comp(tH, .MeshRenderer)
		mr := cast(^MeshRenderer)mr_raw
		for m in gltf_mesh_materials(node.mesh) {
			g: Asset_GUID
			if m != nil {
				mi := int(cgltf.material_index(data, m))
				if mi < len(material_guids) do g = material_guids[mi]
			}
			append(&mr.materials, g)
		}
	}

	for child in node.children {
		_scene_gltf_add_node(data, child, tH, mesh_guid, material_guids)
	}
}
