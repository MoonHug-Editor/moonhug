# Meshes

3D meshes imported from glTF and rendered via MeshFilter + MeshRenderer.
Part of the [SDL3 Renderer](SDL3Renderer.md) work — pipeline details and
history live there.

## Authoring

- Put a `.glb` under `assets/` (a `.gltf` + external `.bin` pair also works,
  but the `.bin` gets its own harmless guid/meta from the AssetDB walk —
  prefer `.glb`).
- The asset pipeline imports it automatically (importer "mesh"); the project
  inspector shows `MeshSettings{scale}` — a uniform import scale.
- Add **MeshFilter** (pick the mesh — the Object Picker lists only
  glb/gltf via the field's `ext:` tag) and **MeshRenderer** (a `materials`
  list of [Material](Materials.md) assets, one per submesh; missing/empty
  entries render white unlit) to a transform.

Unity parity: MeshFilter references the mesh DATA, MeshRenderer decides how
it draws (via its Materials — submesh i uses `materials[i]`).

## Import behavior

One import writes the whole-model artifact plus one **part** artifact per
glTF mesh:

- **Whole model** (`MeshFilter.part == 0`, the default): all triangle
  primitives BAKED (node world transforms applied) into one vertex blob.
- **Parts** (`MeshFilter.part == N` = glTF mesh N−1): that mesh's primitives
  in NODE-LOCAL space — the transform hierarchy positions them at draw time,
  so animated node transforms move real geometry. "Extract Assets" writes a
  .scene wiring mesh nodes to their parts.

In both, indices are grouped **by glTF material** into submeshes (primitives
sharing a material merge into one submesh, ordered by first appearance — the
Unity model; across the file for the whole model, within the mesh for a
part):

- missing normals → flat `{0,0,1}` (fine for the unlit shader)
- missing uvs → zero
- uvs are taken as-authored and mesh draws sample with REPEAT wrap (the glTF
  default) — models with UVs outside [0,1] (offset islands, tiling) render
  correctly; sprites/batch quads still sample CLAMP
- negative-scale nodes → triangle winding flipped (front faces survive a
  future backface-culling switch)
- vertex format = `gfx.Vertex` (position, normal, uv, color) — normals feed
  the built-in lit shader
- glTF material PROPERTIES (base color, textures) are not imported — moonhug
  materials are authored as `.mat` assets; the glTF materials only define the
  submesh split

`multimat_cube.glb` (assets/meshes) is a generated two-material test model:
4 side faces = submesh 0, top+bottom = submesh 1.

## Artifact format

`library/artifacts/<guid>.bin` (whole model) and `<guid>_m<i>.bin` (part =
glTF mesh i), little-endian, same layout (see `asset_importer_mesh.odin`):

```
"MHMESH2\0" | vertex_count u32 | index_count u32 | submesh_count u32 |
aabb_min [3]f32 | aabb_max [3]f32 |
vertices [vertex_count]gfx.Vertex | indices [index_count]u32 |
submeshes [submesh_count]{first_index u32, index_count u32}
```

v2 added the submesh table; stale v1 artifacts fail the magic check and
`mesh_load` reimports from source automatically.

The AABB is computed at import and kept CPU-side by the mesh cache — it's
what makes scene-view picking and the selection outline cheap (no runtime
vertex data on the CPU).

## Runtime

`mesh_load(guid, part)` (engine/mesh.odin) mirrors the texture cache:
artifact → GPU buffers + submesh table, cached by (guid, part). A missing OR
stale artifact
(fresh clone, cleaned `library/`, format bump) triggers reimport from the
source glTF. Headless contexts (tests) get a graceful `false` — no GPU device
required to load scenes that contain mesh components. Rendering draws each
submesh as an index-range `gfx.draw_mesh` with its own material state.
