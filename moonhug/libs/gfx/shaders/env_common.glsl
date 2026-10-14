// Shared by the image-based light's shaders (env_*.frag, skybox.frag).

const float PI = 3.14159265359;

// The direction a cube face's texel looks along: face 0..5 is +X, -X, +Y,
// -Y, +Z, -Z, uv (0, 0) is the face's top-left (fullscreen.vert's frag_uv).
// The APIs' own face orientation, so a samplerCube lookup lands back here.
vec3 face_dir(int face, vec2 uv) {
    vec2 p = uv * 2.0 - 1.0;
    vec3 d;
    if (face == 0)      d = vec3( 1.0, -p.y, -p.x);
    else if (face == 1) d = vec3(-1.0, -p.y,  p.x);
    else if (face == 2) d = vec3( p.x,  1.0,  p.y);
    else if (face == 3) d = vec3( p.x, -1.0, -p.y);
    else if (face == 4) d = vec3( p.x, -p.y,  1.0);
    else                d = vec3(-p.x, -p.y, -1.0);
    return normalize(d);
}

// An orthonormal frame around `n`.
void basis(vec3 n, out vec3 t, out vec3 b) {
    vec3 up = abs(n.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
    t = normalize(cross(up, n));
    b = cross(n, t);
}
