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
  glb/gltf via the field's `ext:` tag) and **MeshRenderer** (texture + tint;
  empty texture renders untextured white) to a transform.

Unity parity: MeshFilter references the mesh DATA, MeshRenderer decides how
it draws. A Material asset replacing MeshRenderer's raw texture/color is the
designated follow-up once more than one shader exists.

## Import behavior

All of the glTF's triangle primitives are BAKED (node world transforms
applied) and merged into one vertex/index blob:

- missing normals → flat `{0,0,1}` (fine for the unlit shader)
- missing uvs → zero
- negative-scale nodes → triangle winding flipped (front faces survive a
  future backface-culling switch)
- vertex format = `gfx.Vertex` (position, normal, uv, color) — normals are
  reserved for lighting

Multi-material/submesh splitting is NOT done yet; the artifact header
reserves `submesh_count` (=1) so the format won't break when it lands.

## Artifact format

`library/artifacts/<guid>.bin`, little-endian (see `asset_importer_mesh.odin`):

```
"MHMESH1\0" | vertex_count u32 | index_count u32 | submesh_count u32 |
aabb_min [3]f32 | aabb_max [3]f32 |
vertices [vertex_count]gfx.Vertex | indices [index_count]u32
```

The AABB is computed at import and kept CPU-side by the mesh cache — it's
what makes scene-view picking and the selection outline cheap (no runtime
vertex data on the CPU).

## Runtime

`mesh_load(guid)` (engine/mesh.odin) mirrors the texture cache: artifact →
GPU buffers, cached by guid. A missing artifact (fresh clone, cleaned
`library/`) triggers reimport from the source glTF. Headless contexts (tests)
get a graceful `false` — no GPU device required to load scenes that contain
mesh components.
