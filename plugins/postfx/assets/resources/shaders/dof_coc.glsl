// Depth of field, pass 1: the scene at half size with each pixel's circle
// of confusion in alpha, from a thin lens: focal length, aperture and focus
// distance give the circle a point at depth d makes on the sensor (24 mm
// high), scaled to pixels of the half-size image. Negative in front of the
// focus (near), positive behind it (far), capped at the max radius. Each
// half-size texel averages the colour of its 2 x 2 pixels and takes the
// circle of the one nearest the camera, so a near object keeps its spread.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D tex;   // the scene, full size
layout(set = 2, binding = 1) uniform sampler2D depth; // its depth

layout(set = 3, binding = 1) uniform MaterialUBO {
    mat4 inv_proj; // the camera's inverse projection, for the view depth
    vec4 params;   // x = focus distance (world units), y = focal length (world units), z = aperture diameter (world units), w = max radius (half-size pixels)
    vec4 params2;  // x = half-size pixels per sensor height
};

// The view-space distance of the surface at pixel `p` of the full image.
float view_depth(ivec2 p, ivec2 size) {
    p = clamp(p, ivec2(0), size - 1);
    float d = texelFetch(depth, p, 0).r;
    vec2 uv = (vec2(p) + 0.5) / vec2(size);
    vec4 v = inv_proj * vec4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, d, 1.0);
    return -v.z / v.w;
}

float coc(float d) {
    float focus = params.x, f = params.y, aperture = params.z;
    float c = aperture * f * (d - focus) / (max(d, 1e-3) * max(focus - f, 1e-3));
    return clamp(c * params2.x, -params.w, params.w);
}

void main() {
    ivec2 size = textureSize(tex, 0);
    ivec2 p = ivec2(frag_uv * vec2(size));
    p -= p & 1; // the 2 x 2 block's top-left pixel
    vec3 sum = vec3(0.0);
    float nearest = 1e9;
    for (int y = 0; y < 2; ++y) {
        for (int x = 0; x < 2; ++x) {
            ivec2 q = clamp(p + ivec2(x, y), ivec2(0), size - 1);
            sum += texelFetch(tex, q, 0).rgb;
            nearest = min(nearest, view_depth(q, size));
        }
    }
    out_color = vec4(sum * 0.25, coc(nearest));
}
