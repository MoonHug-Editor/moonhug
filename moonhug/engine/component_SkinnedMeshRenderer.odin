package engine

// SkinnedMeshRenderer: draws a mesh deformed by a skeleton of transforms.
//
// Skinning is done on the CPU. Every frame the bind-pose vertices are rebuilt
// through the current skin matrices and uploaded to a per-renderer dynamic
// vertex buffer, then drawn with the ordinary mesh pipeline. That keeps the
// whole feature inside this layer: no vertex format change, no shader variant,
// no bone matrix buffer. GPU skinning is the faster answer at high character
// counts and is a drop-in replacement later — the binding and the matrix
// palette computed here are exactly what a vertex shader would need.
//
// JOINTS ARE SCENE TRANSFORMS, found by NAME, the same way animation channels
// find theirs. So a skinned character animates through the existing clip and
// TimelineAnimator paths with nothing added: a clip moves the joint transforms,
// this reads them.
//
// The renderer's OWN transform does not move the mesh. Skin matrices already
// carry each joint's world transform, so the result is world space and the
// draw uses an identity model matrix. Moving a character means moving its root
// bone, which is the glTF rule and Unity's.

import "core:math/linalg"
import gfx "gfx"
import "log"

@(component={menu="Mesh/SkinnedMeshRenderer"})
@(typ_guid={guid = "5f2e77c4-8a3b-4d19-9e06-1c7b4a2f3d85"})
SkinnedMeshRenderer :: struct {
    using base: CompData `inspect:"-"`,

    // One material per submesh, like MeshRenderer.
    materials: [dynamic]Asset_GUID `ext:"mat"`,

    // Where joint names are resolved from. Unset searches the parent's subtree,
    // which is where an extracted glTF puts the armature next to the mesh.
    root_bone: Ref_Local `ref:"Transform"`,

    // Runtime. `joints` is parallel to the mesh's joint_names, `posed` is the
    // CPU skinning scratch, `gpu` the buffer it is uploaded to.
    joints:      [dynamic]Transform_Handle `json:"-" inspect:"-"`,
    posed:       [dynamic]gfx.Vertex `json:"-" inspect:"-"`,
    gpu:         gfx.Dynamic_Mesh `json:"-" inspect:"-"`,
    bound_guid:  Asset_GUID `json:"-" inspect:"-"`, // what `joints` was built for
    bound_part:  i32 `json:"-" inspect:"-"`,
    bound_ready: bool `json:"-" inspect:"-"`,
    posed_frame: u64 `json:"-" inspect:"-"`, // gfx.frame_index the skinning last ran in
}

on_destroy_SkinnedMeshRenderer :: proc(smr: ^SkinnedMeshRenderer) {
    cleanup_SkinnedMeshRenderer(smr)
}

cleanup_SkinnedMeshRenderer :: proc(smr: ^SkinnedMeshRenderer) {
    if smr.bound_ready do gfx.dynamic_mesh_destroy(&smr.gpu)
    delete(smr.joints)
    delete(smr.posed)
    if smr.materials != nil do delete(smr.materials)
    comp_zero(smr)
}

// Depth-first search for a transform by name.
@(private = "file")
_bone_by_name :: proc(h: Transform_Handle, name: string) -> (Transform_Handle, bool) {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(h))
    if t == nil do return {}, false
    if t.name == name do return h, true
    for ch in t.children {
        if got, ok := _bone_by_name(Transform_Handle(ch.handle), name); ok do return got, true
    }
    return {}, false
}

// The subtree joint names are looked up in: the explicit root bone, else the
// renderer's parent (mesh and armature usually sit side by side), else the
// renderer itself.
@(private = "file")
_skin_search_root :: proc(smr: ^SkinnedMeshRenderer) -> Transform_Handle {
    w := ctx_world()
    if world_pool_valid(w, smr.root_bone.handle) {
        if base := cast(^CompData)world_pool_get(w, smr.root_bone.handle); base != nil {
            return base.owner
        }
    }
    if t := pool_get(&w.transforms, Handle(smr.owner)); t != nil && t.parent.handle != {} {
        return Transform_Handle(t.parent.handle)
    }
    return smr.owner
}

// Resolve every joint name to a transform and allocate the skinning buffers.
// Rebuilt when the referenced mesh changes; a joint that never resolves stays
// zero and contributes its bind pose, so a partial skeleton deforms what it
// can rather than collapsing the mesh.
@(private = "file")
_skin_bind :: proc(smr: ^SkinnedMeshRenderer, mesh: ^Mesh, guid: Asset_GUID, part: i32) -> bool {
    if smr.bound_ready && smr.bound_guid == guid && smr.bound_part == part do return true
    if smr.bound_ready do gfx.dynamic_mesh_destroy(&smr.gpu)
    clear(&smr.joints)
    smr.bound_ready = false

    root := _skin_search_root(smr)
    missing := 0
    if smr.joints == nil do smr.joints = make([dynamic]Transform_Handle)
    for name in mesh.joint_names {
        h, ok := _bone_by_name(root, name)
        if !ok do missing += 1
        append(&smr.joints, h)
    }
    if missing > 0 {
        log.infof("[Skin] %d of %d joints not found under %q — those vertices keep their bind pose",
            missing, len(mesh.joint_names), _transform_name(root))
    }

    indices := _mesh_indices_of(mesh)
    if len(indices) == 0 do return false
    smr.gpu = gfx.dynamic_mesh_create(len(mesh.bind_vertices), indices)
    if smr.gpu.index_count == 0 do return false

    if smr.posed == nil do smr.posed = make([dynamic]gfx.Vertex)
    resize(&smr.posed, len(mesh.bind_vertices))
    smr.bound_guid, smr.bound_part, smr.bound_ready = guid, part, true
    return true
}

@(private = "file")
_transform_name :: proc(h: Transform_Handle) -> string {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(h))
    return t != nil ? t.name : "<gone>"
}

// Rebuild the posed vertices from the bind pose through the current joint
// world transforms, and upload them.
@(private = "file")
_skin_pose :: proc(smr: ^SkinnedMeshRenderer, mesh: ^Mesh) {
    w := ctx_world()
    // skin[j] = joint world * inverse bind. The inverse bind puts a vertex into
    // the joint's local space at bind time, the world matrix puts it back where
    // the joint is now.
    palette := make([]matrix[4, 4]f32, len(mesh.inverse_binds), context.temp_allocator)
    for j in 0 ..< len(palette) {
        palette[j] = linalg.MATRIX4F32_IDENTITY
        if j >= len(smr.joints) do continue
        h := smr.joints[j]
        if !pool_valid(&w.transforms, Handle(h)) do continue
        tw := transform_world(h)
        palette[j] = trs_matrix(tw.position, tw.rotation, tw.scale) * mesh.inverse_binds[j]
    }

    for i in 0 ..< len(mesh.bind_vertices) {
        v := mesh.bind_vertices[i]
        sv := mesh.skin[i]

        pos: [3]f32
        nrm: [3]f32
        total: f32
        for k in 0 ..< 4 {
            wgt := sv.weights[k]
            if wgt <= 0 do continue
            ji := int(sv.joints[k])
            if ji >= len(palette) do continue
            m := palette[ji]
            p4 := m * [4]f32{v.position.x, v.position.y, v.position.z, 1}
            pos += wgt * p4.xyz
            n3 := matrix[3, 3]f32{
                m[0, 0], m[0, 1], m[0, 2],
                m[1, 0], m[1, 1], m[1, 2],
                m[2, 0], m[2, 1], m[2, 2],
            }
            nrm += wgt * (n3 * v.normal)
            total += wgt
        }
        // No usable weight: keep the bind pose rather than collapsing to the
        // origin, which is what an unresolved skeleton looks like otherwise.
        if total > 0 {
            v.position = pos / total
            v.normal = linalg.normalize0(nrm)
        }
        smr.posed[i] = v
    }
    gfx.dynamic_mesh_update(&smr.gpu, smr.posed[:])
}

// Hand every enabled SkinnedMeshRenderer's draw to `out`. Called from the
// render collector once PER VIEW, so the draw command is appended for each
// view but the skinning itself runs once per frame per renderer — the frame
// stamp below. Skinning is a pure function of the bind pose and the current
// joint transforms, so a second view in the same frame would rebuild identical
// vertices and upload them again.
skinned_mesh_collect :: proc(out: ^[dynamic]Render_Command, view: Render_View) {
    w := ctx_world()
    it := pool_iterator(skinned_mesh_renderers(w))
    for smr, _ in pool_next(&it) {
        if !smr.enabled do continue
        t := pool_get(&w.transforms, Handle(smr.owner))
        if t == nil || !transform_active_in_hierarchy(smr.owner) do continue
        if t.render_layer & view.layer_mask == 0 do continue

        _, mf := transform_get_comp(Transform_Handle(smr.owner), MeshFilter)
        if mf == nil || asset_guid_is_empty(mf.mesh.guid) do continue
        part, part_ok := mesh_filter_part(mf)
        if !part_ok do continue
        mesh, mesh_ok := mesh_load(mf.mesh.guid, part)
        if !mesh_ok || !mesh_is_skinned(mesh) do continue

        if !_skin_bind(smr, mesh, mf.mesh.guid, part) do continue
        // Safe because nothing moves a joint between two collects of one
        // frame: the editor loop runs sim_tick and preview.apply_all before
        // the scene and game views draw and preview.restore_all after both
        // (editor/main.odin), and the app loop updates, then renders.
        if smr.posed_frame != gfx.frame_index {
            _skin_pose(smr, mesh)
            smr.posed_frame = gfx.frame_index
        }

        // Identity model: skin matrices already produced world space.
        append(out, Render_Command{
            variant = Draw_Mesh{
                mesh      = mf.mesh.guid,
                part      = part,
                materials = smr.materials[:],
                model     = linalg.MATRIX4F32_IDENTITY,
                skinned   = &smr.gpu.mesh,
            },
        })
    }
}
