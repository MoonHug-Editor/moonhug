// Bloom, the upsample chain: one level of the downsample chain blended with
// the next smaller level, upsampled with a 3x3 tent filter (Jimenez). The
// blend is `scatter`: 0 keeps the sharper level, 1 the wider glow beneath.
// Each level carries every smaller one, so the last pass holds the glow of
// every size, times a scale (1, then the bloom's strength on the last).
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D tex;   // the level this pass writes the size of
layout(set = 2, binding = 1) uniform sampler2D lower; // the smaller level, already combined

layout(set = 3, binding = 1) uniform MaterialUBO {
    vec4 params; // xy = one texel of `lower` in uv, z = scatter, w = scale
};

void main() {
    vec2 t = params.xy;
    vec3 low = texture(lower, frag_uv).rgb * 4.0;
    low += (texture(lower, frag_uv + vec2(t.x, 0.0)).rgb + texture(lower, frag_uv - vec2(t.x, 0.0)).rgb
          + texture(lower, frag_uv + vec2(0.0, t.y)).rgb + texture(lower, frag_uv - vec2(0.0, t.y)).rgb) * 2.0;
    low += texture(lower, frag_uv + t).rgb + texture(lower, frag_uv - t).rgb
         + texture(lower, frag_uv + vec2(t.x, -t.y)).rgb + texture(lower, frag_uv + vec2(-t.x, t.y)).rgb;
    low /= 16.0;
    vec3 high = texture(tex, frag_uv).rgb;
    out_color = vec4(mix(high, low, params.z) * params.w, 1.0);
}
