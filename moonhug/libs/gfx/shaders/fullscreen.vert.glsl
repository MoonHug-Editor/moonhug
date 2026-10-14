// Fullscreen triangle from gl_VertexIndex, no vertex buffer: three vertices
// cover the whole target, uv is 0..1 across it with v down (texture rows are
// top-down in SDL_GPU targets). Every fullscreen fragment shader (blit, post
// effects) pairs with this vertex stage, see gfx draw_fullscreen.
#version 450

layout(location = 0) out vec2 frag_uv;

void main() {
    vec2 pos = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    frag_uv = pos;
    gl_Position = vec4(pos * 2.0 - 1.0, 0.0, 1.0);
    gl_Position.y = -gl_Position.y;
}
