// Fixture mirroring the view-dependent shading contract (assets/shaders/
// specular.glsl): frag_world_pos input (loc 3) + LightUBO with cam_pos.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;
layout(location = 2) in vec3 frag_normal;
layout(location = 3) in vec3 frag_world_pos;

layout(set = 2, binding = 0) uniform sampler2D tex;

#define MAX_LIGHTS 8
struct GpuLight {
    vec4 pos_type;    // xyz = position, w = kind (0 dir, 1 point, 2 spot)
    vec4 dir_range;   // xyz = normalized travel direction, w = range
    vec4 color_outer; // rgb premultiplied by intensity, w = cos outer half-angle
    vec4 params;      // x = cos inner half-angle, yzw reserved
};
layout(set = 3, binding = 0) uniform LightUBO {
    vec4 ambient_count; // x = ambient floor, y = light count
    vec4 cam_pos;       // xyz = camera world position
    GpuLight lights[MAX_LIGHTS];
};

layout(set = 3, binding = 1) uniform MaterialUBO {
    vec4  spec_color;
    float shininess;
};

layout(location = 0) out vec4 out_color;

void main() {
    vec3 n = normalize(frag_normal);
    vec3 to_cam = normalize(cam_pos.xyz - frag_world_pos);
    vec3 half_dir = normalize(-lights[0].dir_range.xyz + to_cam);
    float shiny = shininess <= 0.0 ? 32.0 : shininess;
    float spec = pow(max(dot(n, half_dir), 0.0), shiny);
    vec4 base = texture(tex, frag_uv) * frag_color;
    out_color = vec4(base.rgb + spec_color.rgb * spec, base.a);
}
