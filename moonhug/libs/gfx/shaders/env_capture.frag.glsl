// The sky into one face of the environment cube: a procedural gradient with
// a sun, a panorama (an equirectangular color texture), or one color, times
// the exposure. Linear light out.
// SDL_GPU SPIR-V convention: fragment samplers in set 2, uniforms in set 3.
#version 450

#include "env_common.glsl"

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D panorama;

layout(set = 3, binding = 1) uniform Params {
    vec4 face_mode;   // x face, y mode (0 procedural, 1 panorama, 2 color), z panorama yaw (radians), w exposure
    vec4 sky_top;     // rgb linear: the zenith (and the color mode's color)
    vec4 sky_horizon; // rgb linear
    vec4 ground;      // rgb linear
    vec4 sun_dir;     // xyz toward the sun, w cos of the sun's angular radius
    vec4 sun_color;   // rgb linear times intensity, zero for no sun
};

vec3 srgb_to_linear(vec3 c) {
    return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, vec3(lessThanEqual(c, vec3(0.04045))));
}

vec3 procedural(vec3 d) {
    float y = d.y;
    vec3 c = y >= 0.0
        ? mix(sky_horizon.rgb, sky_top.rgb, pow(y, 0.45))
        : mix(sky_horizon.rgb, ground.rgb, pow(min(-y * 4.0, 1.0), 0.5));
    float mu = max(dot(d, sun_dir.xyz), 0.0);
    float above = smoothstep(-0.02, 0.02, y);
    // The glow around the sun, then its disc with a soft edge.
    c += sun_color.rgb * (0.06 * pow(mu, 6.0) + 0.3 * pow(mu, 96.0)) * above;
    float edge = (1.0 - sun_dir.w) * 0.3;
    c += sun_color.rgb * 6.0 * smoothstep(sun_dir.w - edge, sun_dir.w, dot(d, sun_dir.xyz)) * above;
    return c;
}

vec3 panorama_color(vec3 d) {
    float u = atan(d.z, d.x) / (2.0 * PI) + 0.5 + face_mode.z / (2.0 * PI);
    float v = acos(clamp(d.y, -1.0, 1.0)) / PI;
    return srgb_to_linear(textureLod(panorama, vec2(fract(u), v), 0.0).rgb);
}

void main() {
    vec3 d = face_dir(int(face_mode.x + 0.5), frag_uv);
    int mode = int(face_mode.y + 0.5);
    vec3 c = mode == 0 ? procedural(d) : (mode == 1 ? panorama_color(d) : sky_top.rgb);
    out_color = vec4(c * face_mode.w, 1.0);
}
