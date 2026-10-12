package engine

// SkinnedMeshRenderer: draws a mesh deformed by a skeleton of transforms.
//
// Skinning runs on the GPU. Every frame the joint matrix palette is built from
// the current joint transforms and uploaded, and a compute pass (gfx/skinning)
// writes the posed vertices into this renderer's own vertex buffer, which is
// then drawn with the ordinary mesh pipeline: no vertex format change and no
// shader variant in any graphics pass. The bind pose and the skin data are
// the mesh's, uploaded once and shared by every renderer of it.
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
import "core:slice"
import gfx "moonhug:libs/gfx"
import "moonhug:libs/log"

@(component={menu="Mesh/SkinnedMeshRenderer"})
@(typ_guid={guid = "5f2e77c4-8a3b-4d19-9e06-1c7b4a2f3d85"})
SkinnedMeshRenderer :: struct {
    using base: CompData `inspect:"-"`,

    // One material per submesh, like MeshRenderer.
    materials: [dynamic]Asset_GUID `ext:"mat" expand`,

    // Where joint names are resolved from. Unset searches the parent's subtree,
    // which is where an extracted glTF puts the armature next to the mesh.
    root_bone: Ref_Local `ref:"Transform"`,

    // Runtime. `joints` is parallel to the mesh's joint_names, `gpu` the
    // palette and the posed vertex buffer the compute pass writes.
    joints:      [dynamic]Transform_Handle `json:"-" inspect:"-"`,
    gpu:         gfx.Skinned_Mesh `json:"-" inspect:"-"`,
    bound_guid:  Asset_GUID `json:"-" inspect:"-"`, // what `joints` was built for
    bound_part:  i32 `json:"-" inspect:"-"`,
    bound_root:  Transform_Handle `json:"-" inspect:"-"`, // the subtree it searched
    bound_ready: bool `json:"-" inspect:"-"`,
    posed_frame: u64 `json:"-" inspect:"-"`, // gfx.frame_index the skinning last ran in
    // The skin matrices the posed buffer was built from. A frame whose palette
    // is equal keeps the buffer: an idle pose costs one palette build and
    // compare, not an upload and a dispatch.
    palette:     [dynamic]matrix[4, 4]f32 `json:"-" inspect:"-"`,
    // World bounds of the posed mesh, computed by _skin_pose from the palette
    // and the bind-pose box (see there). Kept because the skinned bounds are
    // the only ones that describe where the mesh actually IS — the mesh's own
    // aabb is the bind pose in the skeleton's space, which a posed character
    // has usually left entirely. `posed_ok` says they have been computed.
    posed_min:   [3]f32 `json:"-" inspect:"-"`,
    posed_max:   [3]f32 `json:"-" inspect:"-"`,
    posed_ok:    bool `json:"-" inspect:"-"`,
}

// World-space bounds of the skinned mesh as of the last pose. The skin
// matrices produce world space directly (see _skin_pose), which is why the
// draw command uses an identity model and why nothing is transformed here.
//
// False until the renderer has been skinned at least once. Before that the
// only bounds available are the bind pose's, which sit wherever the skeleton
// was authored rather than where the object is, so this reports nothing rather
// than reporting somewhere wrong.
skinned_mesh_world_bounds :: proc(smr: ^SkinnedMeshRenderer) -> (lo, hi: [3]f32, ok: bool) {
    if smr == nil || !smr.posed_ok do return {}, {}, false
    return smr.posed_min, smr.posed_max, true
}

on_destroy_SkinnedMeshRenderer :: proc(smr: ^SkinnedMeshRenderer) {
    cleanup_SkinnedMeshRenderer(smr)
}

cleanup_SkinnedMeshRenderer :: proc(smr: ^SkinnedMeshRenderer) {
    if smr.bound_ready do gfx.skinned_mesh_destroy(&smr.gpu)
    delete(smr.joints)
    delete(smr.palette)
    if smr.materials != nil do delete(smr.materials)
    comp_zero(smr)
}

// False when a joint that RESOLVED at bind time is dead now: the skeleton was
// rebuilt under us by a delete and recreate, an undo, or a prefab reload.
// Holding the dead handle would pose that joint's bind pose forever, so the
// binding is thrown away and the names are resolved again.
//
// A joint that never resolved stays zero and is not a reason to rebind — it is
// already reported at bind time and rebinding would just repeat the search.
skin_joints_alive :: proc(smr: ^SkinnedMeshRenderer) -> bool {
    w := ctx_world()
    for h in smr.joints {
        if h == {} do continue
        if !pool_valid(&w.transforms, Handle(h)) do return false
    }
    return true
}

// Re-resolve the joints by name. Renaming a bone is not observable from here —
// no hierarchy version exists and names are written directly — so a rename after
// bind needs this. A deleted joint or a repointed root bone rebinds on its own.
@(inspector_button={label="Rebind Joints", row=-1})
skinned_mesh_rebind :: proc(smr: ^SkinnedMeshRenderer) {
    smr.bound_ready = false
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
    root := _skin_search_root(smr)
    // The search root counts as part of the binding: repointing root_bone must
    // re-resolve the joints, not keep the ones found under the old subtree.
    if smr.bound_ready && smr.bound_guid == guid && smr.bound_part == part && smr.bound_root == root {
        return true
    }
    if smr.bound_ready do gfx.skinned_mesh_destroy(&smr.gpu)
    clear(&smr.joints)
    // A new buffer holds nothing yet, so the next pose is built whatever it is.
    clear(&smr.palette)
    smr.bound_ready = false
    smr.posed_ok = false

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

    smr.gpu = gfx.skinned_mesh_create(int(mesh.skin_gpu.vertex_count), len(mesh.inverse_binds), mesh.gpu.ibuf, mesh.gpu.index_count)
    if smr.gpu.index_count == 0 do return false

    smr.bound_guid, smr.bound_part, smr.bound_root, smr.bound_ready = guid, part, root, true
    return true
}

@(private = "file")
_transform_name :: proc(h: Transform_Handle) -> string {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(h))
    return t != nil ? t.name : "<gone>"
}

// Build the palette from the current joint world transforms and, when it
// changed, upload it and run the skinning pass.
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
    if slice.equal(palette, smr.palette[:]) do return
    if smr.palette == nil do smr.palette = make([dynamic]matrix[4, 4]f32)
    resize(&smr.palette, len(palette))
    copy(smr.palette[:], palette)

    // The posed vertices live on the GPU, so the bounds come from the palette:
    // every posed vertex is a weighted mix of its joints' images of a bind-pose
    // point, and each image lies inside that joint's image of the bind box. The
    // union of the eight transformed corners over every joint therefore
    // contains the whole posed mesh. Looser than the exact box, but a bound,
    // and 8 corners per joint instead of a pass over every vertex.
    lo := [3]f32{max(f32), max(f32), max(f32)}
    hi := [3]f32{min(f32), min(f32), min(f32)}
    for m in palette {
        for c in 0 ..< 8 {
            corner := [4]f32{
                c & 1 == 0 ? mesh.aabb_min.x : mesh.aabb_max.x,
                c & 2 == 0 ? mesh.aabb_min.y : mesh.aabb_max.y,
                c & 4 == 0 ? mesh.aabb_min.z : mesh.aabb_max.z,
                1,
            }
            p := (m * corner).xyz
            lo = {min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)}
            hi = {max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)}
        }
    }
    if len(palette) > 0 do smr.posed_min, smr.posed_max, smr.posed_ok = lo, hi, true

    gfx.skinned_mesh_pose(&smr.gpu, mesh.skin_gpu, palette)
}

// Hand every enabled SkinnedMeshRenderer's draw to `out`. Called from the
// render collector once PER VIEW, so the draw command is appended for each
// view but the skinning itself runs once per frame per renderer — the frame
// stamp below. Skinning is a pure function of the bind pose and the current
// joint transforms, so a second view in the same frame would upload the same
// palette and dispatch the same pass again.
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

        // Checked before the bind, so a frame is never drawn through a palette
        // that holds a dead joint.
        if smr.bound_ready && !skin_joints_alive(smr) do smr.bound_ready = false
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
            owner   = Transform_Handle(smr.owner),
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
