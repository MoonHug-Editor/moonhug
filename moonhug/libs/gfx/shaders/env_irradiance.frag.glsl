// One face of the irradiance cube: the source environment's light arriving
// at a surface facing each direction, cosine-weighted over the hemisphere,
// divided by pi so a uniform environment of radiance L gives L (the
// template's diffuse is not divided by pi). Read from a low source mip.
#version 450

#include "env_common.glsl"

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform samplerCube source;

layout(set = 3, binding = 1) uniform Params {
    vec4 face_lod; // x face, y source mip to read
};

void main() {
    vec3 n = face_dir(int(face_lod.x + 0.5), frag_uv);
    vec3 t, b;
    basis(n, t, b);
    vec3 sum = vec3(0.0);
    float count = 0.0;
    // Integer counters, angles at the cell midpoints. With float counters
    // (phi += step) Metal returned about a third of this integral.
    const float step_phi = 2.0 * PI / 48.0;
    const float step_theta = 0.5 * PI / 16.0;
    for (int i = 0; i < 48; ++i) {
        float phi = (float(i) + 0.5) * step_phi;
        for (int j = 0; j < 16; ++j) {
            float theta = (float(j) + 0.5) * step_theta;
            vec3 l = t * (sin(theta) * cos(phi)) + b * (sin(theta) * sin(phi)) + n * cos(theta);
            sum += textureLod(source, l, face_lod.y).rgb * cos(theta) * sin(theta);
            count += 1.0;
        }
    }
    out_color = vec4(PI * sum / count, 1.0);
}
