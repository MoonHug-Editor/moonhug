package engine

// Draws the sibling MeshFilter's mesh with Material assets (material.odin),
// one per submesh (Unity model: submesh i uses materials[i]). Missing or
// empty entries render plain white, lit.

@(component={menu="Mesh/MeshRenderer"})
@(typ_guid={guid = "73e161a0-c599-4cfb-9826-447e05baa76c"})
MeshRenderer :: struct {
    using base: CompData `inspect:"-"`,
    materials:    [dynamic]Asset_GUID `ext:"mat" expand`,
    cast_shadows: Shadow_Casting,
    reflections:  Reflection_Visibility,
}

// Whether a mesh draws into the shadow maps (MeshRenderer and
// SkinnedMeshRenderer cast_shadows).
Shadow_Casting :: enum u8 {
    On,           // casts, each face culled as its material says
    Off,          // never in a shadow map
    Double_Sided, // casts with no face culling: a one-sided plane still shadows from behind
    Shadows_Only, // in the shadow maps only: no colour, depth prepass, normals or probe pass draws it
}

// Whether a mesh shows in reflection probe captures (MeshRenderer and
// SkinnedMeshRenderer reflections).
Reflection_Visibility :: enum u8 {
    Visible,
    Hidden, // left out of every capture: a mirror inside a probe's box would reflect itself
}

// Whether a renderer with these pass flags draws in `pass`, and whether it
// draws there with no face culling (a double-sided caster in a shadow view).
render_pass_includes :: proc(pass: View_Pass, cast_shadows: Shadow_Casting, reflections: Reflection_Visibility) -> (draws: bool, double_sided: bool) {
    switch pass {
    case .Shadow:
        return cast_shadows != .Off, cast_shadows == .Double_Sided
    case .Probe:
        return cast_shadows != .Shadows_Only && reflections != .Hidden, false
    case .Color:
        return cast_shadows != .Shadows_Only, false
    }
    return false, false
}

on_destroy_MeshRenderer :: proc(mr: ^MeshRenderer) {
    cleanup_MeshRenderer(mr)
}

cleanup_MeshRenderer :: proc(mr: ^MeshRenderer) {
    if mr.materials != nil do delete(mr.materials)
    comp_zero(mr)
}
