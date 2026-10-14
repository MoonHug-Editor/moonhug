// Tonemap: HDR scene color (plus the bloom) to display range. The operator
// is a property, so the Post FX settings switch it without a second shader:
//   0  none       clamp, what the engine showed before post effects
//   1  Reinhard   c / (1 + c)
//   2  ACES       Narkowicz's fit of the ACES filmic curve
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D tex;       // the HDR scene
layout(set = 2, binding = 1) uniform sampler2D bloom_tex; // the blurred bloom, white when off

layout(set = 3, binding = 1) uniform MaterialUBO {
    vec4 params; // x = operator, y = exposure, z = bloom strength, w unused
};

vec3 aces(vec3 x) {
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

void main() {
    vec3 c = texture(tex, frag_uv).rgb;
    if (params.z > 0.0) c += texture(bloom_tex, frag_uv).rgb * params.z;
    c *= params.y;
    int op = int(params.x + 0.5);
    if (op == 1) c = c / (1.0 + c);
    else if (op == 2) c = aces(c);
    out_color = vec4(clamp(c, 0.0, 1.0), 1.0);
}
