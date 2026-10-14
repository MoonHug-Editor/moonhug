// Named render targets owned by a view. A pass asks for a target by name and
// gets one of the requested size and format: created on first ask, recreated
// when the size or format changes, freed with the pool. The names are the
// contract between passes ("hdr" written by the scene pass, read by tonemap),
// so neither pass holds the other's texture.
//
// No memory aliasing between targets with disjoint lifetimes: every name is
// its own texture for the pool's lifetime, which is the simple choice at
// editor scale.
package gfx

import "base:runtime"

Target_Pool :: struct {
	targets: map[string]^Render_Target,
}

// The target `name`, sized width x height in `format`. The pointer is stable
// across resizes (the textures inside are recreated), so a caller may keep
// it for the pool's lifetime, but must re-fetch rt_imgui_id after a resize
// like any render target.
pool_target :: proc(p: ^Target_Pool, name: string, width, height: i32, format := Target_Format.LDR) -> ^Render_Target {
	if p.targets == nil do p.targets = make(map[string]^Render_Target, runtime.default_allocator())
	if rt, ok := p.targets[name]; ok {
		if rt.format != format {
			rt_destroy(rt)
			fresh := rt_create(width, height, format)
			p.targets[name] = fresh
			return fresh
		}
		rt_resize(rt, width, height)
		return rt
	}
	rt := rt_create(width, height, format)
	p.targets[runtime_clone(name)] = rt
	return rt
}

// The target `name` if a pass created it already, else nil.
pool_find :: proc(p: ^Target_Pool, name: string) -> ^Render_Target {
	return p.targets[name] or_else nil
}

pool_destroy :: proc(p: ^Target_Pool) {
	for name, rt in p.targets {
		rt_destroy(rt)
		delete(name, runtime.default_allocator())
	}
	delete(p.targets)
	p^ = {}
}

@(private = "file")
runtime_clone :: proc(s: string) -> string {
	buf := make([]u8, len(s), runtime.default_allocator())
	copy(buf, s)
	return string(buf)
}
