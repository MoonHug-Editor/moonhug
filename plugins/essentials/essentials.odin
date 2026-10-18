package essentials

// Reusable engine essentials shipped as package content (docs/core/Plugins.md):
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

// assets/rendering/Default.renderpipeline — the frame a project renders
// through until its Rendering setting names a pipeline of its own: the
// engine's scene nodes, the postfx chain, the final blit.
DEFAULT_PIPELINE_GUID :: "2f6a9c41-8b3d-4a7e-9d15-c0e4b7a2d938"

// assets/rendering/DefaultRenderLayers.asset — the names of the render
// layers until the project's Layers setting names a Render Layers asset of its
// own: layer 0 "Default", layer 31 "Editor".
DEFAULT_RENDER_LAYERS_GUID :: "df291cbd-037a-46f5-bad4-f27e885029c0"

// assets/physics/DefaultPhysicsLayers.asset — the names of the collision
// layers until the project's Layers setting names a Physics Layers asset of
// its own: layer 0 "Default".
DEFAULT_PHYSICS_LAYERS_GUID :: "5911ae6f-d210-4ee5-b7d6-c50a91ead1a0"

import "core:encoding/uuid"
import "moonhug:packages/engine"

@(phase={key=EngineInit, order=-1})
essentials_default_pipeline :: proc() {
	id := uuid.read(DEFAULT_PIPELINE_GUID) or_else uuid.Identifier{}
	engine.render_pipeline_default = engine.Asset_GUID(id)
}

@(phase={key=EngineInit, order=-1})
essentials_default_layers :: proc() {
	render := uuid.read(DEFAULT_RENDER_LAYERS_GUID) or_else uuid.Identifier{}
	physics := uuid.read(DEFAULT_PHYSICS_LAYERS_GUID) or_else uuid.Identifier{}
	engine.render_layers_default = engine.Asset_GUID(render)
	engine.physics_layers_default = engine.Asset_GUID(physics)
}
