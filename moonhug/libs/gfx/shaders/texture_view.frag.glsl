// A texture as the editor's preview shows it: a region of it (uv.xy to uv.zw,
// a sprite slice), one mip level, the channels the view keeps, and alpha
// over a checkerboard. channels.xyzw is 1 for a channel shown. One color
// channel alone shows as grey, alpha alone as grey too. view.x is the mip
// level, view.y the checker cell in target pixels, view.z 1 to show alpha
// over the checker (0 draws the color opaque).
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D tex;

layout(set = 3, binding = 1) uniform Params {
    vec4 uv;
    vec4 channels;
    vec4 view;
};

void main() {
    vec2 at = mix(uv.xy, uv.zw, frag_uv);
    vec4 c = textureLod(tex, at, view.x);

    float cell = max(view.y, 1.0);
    vec2 square = floor(gl_FragCoord.xy / cell);
    vec3 checker = mod(square.x + square.y, 2.0) < 0.5 ? vec3(0.32) : vec3(0.22);

    float color_count = channels.r + channels.g + channels.b;
    vec3 rgb;
    float alpha = 1.0;
    if (color_count == 0.0 && channels.a > 0.5) {
        // Alpha alone: the alpha as grey, opaque.
        rgb = vec3(c.a);
    } else if (color_count == 1.0) {
        // One channel: its value as grey.
        rgb = vec3(dot(c.rgb, channels.rgb));
        alpha = channels.a > 0.5 ? c.a : 1.0;
    } else {
        rgb = c.rgb * channels.rgb;
        alpha = channels.a > 0.5 ? c.a : 1.0;
    }
    if (view.z < 0.5) alpha = 1.0;
    out_color = vec4(mix(checker, rgb, alpha), 1.0);
}
