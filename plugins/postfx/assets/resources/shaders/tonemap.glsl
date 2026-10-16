// Tonemap: HDR scene color (plus the bloom) to display range, graded. In
// order:
//   - the auto exposure (red of `exposure`, white = 1 without it), the
//     bloom added (already exposed and scaled by its strength), the manual
//     exposure
//   - grading in linear light: `balance` (white balance and colour filter),
//     contrast around middle grey in log2, `hue_sat` (hue shift and
//     saturation). The defaults leave the colour as it is
//   - the operator, a property, so one shader serves every choice:
//       0  none       clamp, what the engine showed before post effects
//       1  Reinhard   c / (1 + c)
//       2  ACES       Narkowicz's fit of the ACES filmic curve
//       3  ACES Hill  Stephen Hill's fit (the RRT and ODT with ACES' color
//                     matrices), what the Khronos glTF Sample Viewer uses:
//                     its "exposure boost" variant is this with exposure 1 / 0.6
//   - the lookup texture, in display (sRGB) values: a strip of `size`
//     squares, `size` texels each side. Red runs across each square, green
//     down it, blue picks the square left to right. Blended in by its
//     contribution
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D tex;       // the HDR scene
layout(set = 2, binding = 1) uniform sampler2D bloom_tex; // the blurred bloom, white when off
layout(set = 2, binding = 2) uniform sampler2D exposure;  // 1 x 1, red the auto exposure, white when off
layout(set = 2, binding = 3) uniform sampler2D lut;       // the lookup texture, white when off

layout(set = 3, binding = 1) uniform MaterialUBO {
    vec4 params;  // x = operator, y = exposure, z = 1 when the bloom is bound, w = the lookup texture's contribution (0 = none)
    vec4 grading; // x = contrast (1 = none), y = the lookup texture's size (texels per square side)
    mat4 balance; // white balance and colour filter, before contrast (rgb columns)
    mat4 hue_sat; // hue shift and saturation, after contrast (rgb columns)
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

vec3 linear_to_srgb(vec3 c) {
    return mix(1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, c * 12.92, vec3(lessThanEqual(c, vec3(0.0031308))));
}

vec3 srgb_to_linear(vec3 c) {
    return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, vec3(lessThanEqual(c, vec3(0.04045))));
}

// The lookup texture at an sRGB colour: the two squares around its blue,
// each sampled filtered, blended by blue's fraction between them.
vec3 lookup(vec3 c) {
    float n = grading.y;
    vec2 size = vec2(n * n, n);
    float b = clamp(c.b, 0.0, 1.0) * (n - 1.0);
    float b0 = floor(b);
    float b1 = min(b0 + 1.0, n - 1.0);
    vec2 rg = clamp(c.rg, 0.0, 1.0) * (n - 1.0) + 0.5; // texel centres inside a square
    vec3 s0 = textureLod(lut, (vec2(b0 * n, 0.0) + rg) / size, 0.0).rgb;
    vec3 s1 = textureLod(lut, (vec2(b1 * n, 0.0) + rg) / size, 0.0).rgb;
    return mix(s0, s1, b - b0);
}

void main() {
    vec3 c = texture(tex, frag_uv).rgb * texelFetch(exposure, ivec2(0), 0).r;
    if (params.z > 0.0) c += texture(bloom_tex, frag_uv).rgb;
    c *= params.y;

    c = max(mat3(balance) * c, vec3(0.0));
    if (grading.x != 1.0) {
        const float GREY = 0.18;
        c = exp2((log2(max(c, vec3(1e-6))) - log2(GREY)) * grading.x + log2(GREY));
    }
    c = max(mat3(hue_sat) * c, vec3(0.0));

    int op = int(params.x + 0.5);
    if (op == 1) c = c / (1.0 + c);
    else if (op == 2) c = aces(c);
    else if (op == 3) c = aces_hill(c);
    c = clamp(c, 0.0, 1.0);

    if (params.w > 0.0) {
        vec3 graded = srgb_to_linear(lookup(linear_to_srgb(c)));
        c = mix(c, graded, params.w);
    }
    out_color = vec4(c, 1.0);
}
