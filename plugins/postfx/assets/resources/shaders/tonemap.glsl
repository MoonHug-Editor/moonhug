// Tonemap: HDR scene color (plus the bloom) to display range. The operator
// is a property, so the Post FX settings switch it without a second shader:
//   0  none       clamp, what the engine showed before post effects
//   1  Reinhard   c / (1 + c)
//   2  ACES       Narkowicz's fit of the ACES filmic curve
//   3  ACES Hill  Stephen Hill's fit (the RRT and ODT with ACES' color
//                 matrices), what the Khronos glTF Sample Viewer uses: its
//                 "exposure boost" variant is this with exposure 1 / 0.6
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

// sRGB => XYZ => D65_2_D60 => AP1 => RRT_SAT, columns first.
const mat3 ACES_INPUT = mat3(
    0.59719, 0.07600, 0.02840,
    0.35458, 0.90834, 0.13383,
    0.04823, 0.01566, 0.83777);

// ODT_SAT => XYZ => D60_2_D65 => sRGB.
const mat3 ACES_OUTPUT = mat3(
     1.60475, -0.10208, -0.00327,
    -0.53108,  1.10813, -0.07276,
    -0.07367, -0.00605,  1.07602);

vec3 aces_hill(vec3 c) {
    c = ACES_INPUT * c;
    vec3 a = c * (c + 0.0245786) - 0.000090537;
    vec3 b = c * (0.983729 * c + 0.4329510) + 0.238081;
    c = ACES_OUTPUT * (a / b);
    return clamp(c, 0.0, 1.0);
}

void main() {
    vec3 c = texture(tex, frag_uv).rgb;
    if (params.z > 0.0) c += texture(bloom_tex, frag_uv).rgb * params.z;
    c *= params.y;
    int op = int(params.x + 0.5);
    if (op == 1) c = c / (1.0 + c);
    else if (op == 2) c = aces(c);
    else if (op == 3) c = aces_hill(c);
    out_color = vec4(clamp(c, 0.0, 1.0), 1.0);
}
