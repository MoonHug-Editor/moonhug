package essentials

// Reusable engine essentials shipped as package content (docs/Plugins.md):
// primitive meshes in assets/, referenced by these guid constants (the guids
// live in the committed .meta files and are stable in every project).
// Consumers: physics3d's GameObject/3D Object items today, anything needing
// a unit primitive tomorrow.
//
// Sizes: Cube 1x1x1, Sphere r=0.5, Capsule r=0.5 h=2 (Unity's primitive
// dimensions — collider reset defaults match them exactly).

CUBE_MESH_GUID :: "9b978885-12f8-4d30-be4d-d9c2c2074477"
SPHERE_MESH_GUID :: "833ce54b-c6d8-4d84-b927-edd0ec2cee7b"
CAPSULE_MESH_GUID :: "6902c2a5-44a4-4a0e-b2f5-e2c65d22835f"

// assets/Default.mat — built-in Lit shader, white, no texture.
DEFAULT_MATERIAL_GUID :: "86518465-b823-4eb9-b3f5-c0deef450fc6"

// assets/shaders/pbr.glsl — the sample PBR shader (custom_shader on a
// Material).
PBR_SHADER_GUID :: "d85e072d-e69c-421f-ace2-83b602c98eb0"
