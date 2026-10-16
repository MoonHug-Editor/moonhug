// Bloom, pass 1: what glows. Keeps the color above `threshold`, with a soft
// knee so a surface fades into bloom instead of switching on. Reads the HDR
// scene times the auto exposure (white, 1, without it), so the threshold
// applies to the image as exposed, and writes the half-size bloom source.
//
// Four taps around each half-size pixel (each a filtered 2x2 of the scene),
// clamped to `clamp`, then averaged with weights of 1 / (1 + brightness)
// (Karis): a lone very bright pixel (a firefly, one sparkling highlight)
// cannot outweigh its neighbours and blur into a glowing block, while an
// evenly bright area keeps its brightness.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D tex;
layout(set = 2, binding = 1) uniform sampler2D exposure; // 1 x 1, red the auto exposure

layout(set = 3, binding = 1) uniform MaterialUBO {
    vec4 params; // x = threshold, y = knee, z = clamp, w unused
};

void main() {
    vec2 texel = 1.0 / vec2(textureSize(tex, 0));
    float exposed = texelFetch(exposure, ivec2(0), 0).r;
    vec3 sum = vec3(0.0);
    float weight = 0.0;
    for (int i = 0; i < 4; ++i) {
        vec2 o = vec2((i & 1) == 0 ? -1.0 : 1.0, (i & 2) == 0 ? -1.0 : 1.0) * texel;
        vec3 c = min(texture(tex, frag_uv + o).rgb, vec3(params.z)) * exposed;
        float w = 1.0 / (1.0 + max(c.r, max(c.g, c.b)));
        sum += c * w;
        weight += w;
    }
    vec3 c = sum / weight;
    float brightness = max(c.r, max(c.g, c.b));
    float knee = max(params.y, 1e-4);
    float soft = clamp(brightness - params.x + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee);
    float contribution = max(soft, brightness - params.x) / max(brightness, 1e-4);
    out_color = vec4(c * contribution, 1.0);
}
