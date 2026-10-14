// FXAA: fast approximate anti-aliasing on the final LDR image. The compact
// form: luma at the pixel and its four diagonal neighbours finds the edge,
// the blend runs along it. `params.xy` is one texel in uv.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D tex;

layout(set = 3, binding = 1) uniform MaterialUBO {
    vec4 params; // xy = one texel in uv, zw unused
};

float luma(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

void main() {
    const float SPAN_MAX = 8.0;
    const float REDUCE_MUL = 1.0 / 8.0;
    const float REDUCE_MIN = 1.0 / 128.0;
    vec2 texel = params.xy;

    vec3 rgbNW = texture(tex, frag_uv + vec2(-1.0, -1.0) * texel).rgb;
    vec3 rgbNE = texture(tex, frag_uv + vec2( 1.0, -1.0) * texel).rgb;
    vec3 rgbSW = texture(tex, frag_uv + vec2(-1.0,  1.0) * texel).rgb;
    vec3 rgbSE = texture(tex, frag_uv + vec2( 1.0,  1.0) * texel).rgb;
    vec3 rgbM  = texture(tex, frag_uv).rgb;
    float lNW = luma(rgbNW), lNE = luma(rgbNE), lSW = luma(rgbSW), lSE = luma(rgbSE), lM = luma(rgbM);
    float lMin = min(lM, min(min(lNW, lNE), min(lSW, lSE)));
    float lMax = max(lM, max(max(lNW, lNE), max(lSW, lSE)));

    vec2 dir = vec2(-((lNW + lNE) - (lSW + lSE)), (lNW + lSW) - (lNE + lSE));
    float reduce = max((lNW + lNE + lSW + lSE) * 0.25 * REDUCE_MUL, REDUCE_MIN);
    float rcp = 1.0 / (min(abs(dir.x), abs(dir.y)) + reduce);
    dir = clamp(dir * rcp, vec2(-SPAN_MAX), vec2(SPAN_MAX)) * texel;

    vec3 rgbA = 0.5 * (texture(tex, frag_uv + dir * (1.0 / 3.0 - 0.5)).rgb + texture(tex, frag_uv + dir * (2.0 / 3.0 - 0.5)).rgb);
    vec3 rgbB = rgbA * 0.5 + 0.25 * (texture(tex, frag_uv + dir * -0.5).rgb + texture(tex, frag_uv + dir * 0.5).rgb);
    float lB = luma(rgbB);
    out_color = vec4((lB < lMin || lB > lMax) ? rgbA : rgbB, 1.0);
}
