// Built-in "lit" shader: the surface template with the default surface,
// texture * color with a lambert term per light (surface.glsl,
// surface_main.glsl). A user's surface shader is this file with its own
// surface(), assembled by the importer.
#version 450

#include "surface.glsl"

void surface(inout Surface s) {}

#include "surface_main.glsl"
