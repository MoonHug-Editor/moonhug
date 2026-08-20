package physics3d_editor

// GameObject/3D Object primitives with physics: Transform + MeshFilter (a
// primitive mesh from the ESSENTIALS package) + MeshRenderer (essentials
// Default.mat) + Rigidbody + the matching collider. Collider reset defaults
// match the mesh sizes exactly: cube 1x1x1, sphere r=0.5, capsule r=0.5 h=2.
// Everything lands as ONE undo step; component payloads are recorded AFTER
// their fields are set, so redo restores the mesh reference.

import "core:encoding/uuid"
import "core:fmt"
import essentials "moonhug:packages/essentials"
import "moonhug:engine"
import "moonhug:editor/undo"

@(menu_item={path="GameObject/3D Object/Cube (Physics)", shortcut=""})
create_cube_menu :: proc() {
	_create_primitive("Cube", essentials.CUBE_MESH_GUID, .BoxCollider)
}

@(menu_item={path="GameObject/3D Object/Sphere (Physics)", shortcut=""})
create_sphere_menu :: proc() {
	_create_primitive("Sphere", essentials.SPHERE_MESH_GUID, .SphereCollider)
}

@(menu_item={path="GameObject/3D Object/Capsule (Physics)", shortcut=""})
create_capsule_menu :: proc() {
	_create_primitive("Capsule", essentials.CAPSULE_MESH_GUID, .CapsuleCollider)
}

_record_added :: proc(tH: engine.Transform_Handle, comp_handle: engine.Handle) {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return
	undo.record_add_component(tH, comp_handle, len(t.components) - 1)
}

_add_comp :: proc(tH: engine.Transform_Handle, key: engine.TypeKey) {
	owned, ptr := engine.transform_add_comp(tH, key)
	if ptr == nil do return
	_record_added(tH, owned.handle)
}

_create_primitive :: proc(name: string, mesh_guid: string, collider_key: engine.TypeKey) {
	scene := engine.sm_scene_get_active()
	if scene == nil do return
	root := engine.Transform_Handle(scene.root.handle)

	g := undo.group_begin(fmt.tprintf("Create %s (Physics)", name))
	defer undo.group_end(&g)

	tH := undo.record_create_child(name, root)
	if tH == {} do return

	// References are assigned BEFORE recording so the redo payloads carry
	// them.
	mf_owned, mf_ptr := engine.transform_add_comp(tH, .MeshFilter)
	if mf := cast(^engine.MeshFilter)mf_ptr; mf != nil {
		if guid, err := uuid.read(mesh_guid); err == nil {
			mf.mesh = engine.Asset_GUID(guid)
		}
		_record_added(tH, mf_owned.handle)
	}
	mr_owned, mr_ptr := engine.transform_add_comp(tH, .MeshRenderer)
	if mr := cast(^engine.MeshRenderer)mr_ptr; mr != nil {
		if guid, err := uuid.read(essentials.DEFAULT_MATERIAL_GUID); err == nil {
			append(&mr.materials, engine.Asset_GUID(guid))
		}
		_record_added(tH, mr_owned.handle)
	}
	_add_comp(tH, .Rigidbody)
	_add_comp(tH, collider_key) // reset defaults match the primitive mesh

	undo.group_commit(&g)
}
