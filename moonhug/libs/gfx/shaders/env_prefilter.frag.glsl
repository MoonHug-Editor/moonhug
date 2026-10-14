// One face of the prefiltered specular cube at one roughness: the source
// environment convolved with the GGX lobe (importance sampled, each sample
// read from the source mip whose texel matches the sample's solid angle, so
// few samples stay smooth). Roughness 0 copies the source.
#version 450

#include "env_common.glsl"

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform samplerCube source;

layout(set = 3, binding = 1) uniform Params {
    vec4 face_rough; // x face, y perceptual roughness, z the source's face size, w sample count
};

float radical_inverse(uint bits) {
    bits = (bits << 16u) | (bits >> 16u);
    bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
    bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
    bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
    bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
    return float(bits) * 2.3283064365386963e-10;
}

void main() {
    vec3 n = face_dir(int(face_rough.x + 0.5), frag_uv);
    float roughness = face_rough.y;
    if (roughness < 0.001) {
        out_color = vec4(textureLod(source, n, 0.0).rgb, 1.0);
        return;
    }
    float a = roughness * roughness;
    vec3 t, b;
    basis(n, t, b);
    uint count = uint(face_rough.w);
    float texel_sa = 4.0 * PI / (6.0 * face_rough.z * face_rough.z);
    vec3 sum = vec3(0.0);
    float weight = 0.0;
    for (uint i = 0u; i < count; ++i) {
        vec2 xi = vec2(float(i) / float(count), radical_inverse(i));
        float phi = 2.0 * PI * xi.x;
        float cos_t = sqrt((1.0 - xi.y) / (1.0 + (a * a - 1.0) * xi.y));
        float sin_t = sqrt(1.0 - cos_t * cos_t);
        vec3 h = normalize(t * (sin_t * cos(phi)) + b * (sin_t * sin(phi)) + n * cos_t);
        vec3 l = normalize(2.0 * dot(n, h) * h - n); // view = normal
        float NoL = dot(n, l);
        if (NoL <= 0.0) continue;
        float NoH = max(dot(n, h), 0.0);
        float a2 = a * a;
        float f = (NoH * a2 - NoH) * NoH + 1.0;
        float D = a2 / (PI * f * f);
        float pdf = D * 0.25 + 1e-4;
        float sample_sa = 1.0 / (float(count) * pdf);
        float mip = max(0.5 * log2(sample_sa / texel_sa) + 1.0, 0.0);
        sum += textureLod(source, l, mip).rgb * NoL;
        weight += NoL;
    }
    out_color = vec4(sum / max(weight, 1e-4), 1.0);
}
