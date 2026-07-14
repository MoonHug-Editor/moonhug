// Fixture mirroring the view-dependent shading contract (assets/shaders/
// specular.glsl): frag_world_pos input (loc 3) + LightUBO with cam_pos.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;
layout(location = 2) in vec3 frag_normal;
layout(location = 3) in vec3 frag_world_pos;

layout(set = 2, binding = 0) uniform sampler2D tex;

layout(set = 3, binding = 0) uniform LightUBO {
    vec4 light_dir_ambient;
    vec4 light_color;
    vec4 cam_pos;
};

layout(set = 3, binding = 1) uniform MaterialUBO {
    vec4  spec_color;
    float shininess;
};

layout(location = 0) out vec4 out_color;

void main() {
    vec3 n = normalize(frag_normal);
    vec3 to_cam = normalize(cam_pos.xyz - frag_world_pos);
    vec3 half_dir = normalize(-light_dir_ambient.xyz + to_cam);
    float shiny = shininess <= 0.0 ? 32.0 : shininess;
    float spec = pow(max(dot(n, half_dir), 0.0), shiny);
    vec4 base = texture(tex, frag_uv) * frag_color;
    out_color = vec4(base.rgb + spec_color.rgb * spec, base.a);
}
