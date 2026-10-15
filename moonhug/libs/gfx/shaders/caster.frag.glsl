// The built-in caster: the surface template's depth-pass variant with the
// default surface(). The Lit and Unlit shaders draw alpha-clipped meshes
// with it in depth passes (shadow casters, the depth prepass): their alpha
// is the texture's times the color's, the template's preset.
#version 450

#define MOONHUG_CASTER
#include "surface.glsl"

void surface(inout Surface s) {}

#include "surface_main.glsl"
