// The ambient occlusion's blur (the engine's scene_ssao step), one direction
// per pass: a 9-tap Gaussian whose taps count less the further their depth
// (green) lies from the centre's, so occlusion does not bleed across an
// object's edge. Red and green out as in, blue the factor for direct light:
// `params.z` of the occlusion.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_ao;

layout(set = 2, binding = 0) uniform sampler2D ao;

layout(set = 3, binding = 1) uniform Params {
    vec4 params; // xy = the step between taps, in pixels (1, 0 or 0, 1), z = how much of the occlusion darkens direct light
};

void main() {
    ivec2 size = textureSize(ao, 0);
    ivec2 p = clamp(ivec2(frag_uv * vec2(size)), ivec2(0), size - 1);
    vec2 centre = texelFetch(ao, p, 0).rg;
    const float weights[5] = float[](0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216);
    float sum = centre.r * weights[0];
    float total = weights[0];
    ivec2 step = ivec2(params.xy);
    for (int i = 1; i <= 4; ++i) {
        for (int side = -1; side <= 1; side += 2) {
            vec2 s = texelFetch(ao, clamp(p + step * i * side, ivec2(0), size - 1), 0).rg;
            // Relative depth difference: 10% apart counts about a third.
            float w = weights[i] * exp(-abs(s.g - centre.g) / max(centre.g * 0.1, 1e-3));
            sum += s.r * w;
            total += w;
        }
    }
    float open = sum / total;
    out_ao = vec4(open, centre.g, mix(1.0, open, params.z), 1.0);
}
