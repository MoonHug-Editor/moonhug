// Built-in "lit" shader: the surface template with the default surface and
// the engine Material's lit block (metallic, smoothness, normal, occlusion
// and emission maps), physically based (surface.glsl, surface_main.glsl). A
// user's surface shader is this file with its own surface() and without the
// lit block, assembled by the importer.
#version 450

#define MOONHUG_LIT_MATERIAL
#include "surface.glsl"

void surface(inout Surface s) {}

#include "surface_main.glsl"
