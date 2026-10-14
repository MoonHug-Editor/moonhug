// Bloom, pass 1: what glows. Keeps the color above `threshold`, with a soft
// knee so a surface fades into bloom instead of switching on. Reads the HDR
// scene, writes the half-size bloom source.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D tex;

layout(set = 3, binding = 1) uniform MaterialUBO {
    vec4 params; // x = threshold, y = knee, zw unused
};

void main() {
    vec3 c = texture(tex, frag_uv).rgb;
    float brightness = max(c.r, max(c.g, c.b));
    float knee = max(params.y, 1e-4);
    float soft = clamp(brightness - params.x + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee);
    float contribution = max(soft, brightness - params.x) / max(brightness, 1e-4);
    out_color = vec4(c * contribution, 1.0);
}
