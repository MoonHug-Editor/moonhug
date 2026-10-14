package engine

// The scene's image-based light and sky (component_Environment.odin).
//
//   environment_pass (frame lane) renders the first enabled Environment into
//                    cubes, only when its settings, its panorama or the sun
//                    changed: the sky itself (the source, with mips), its
//                    GGX-prefiltered reflection along the mips of a second
//                    cube, and its diffuse irradiance in a third
//   scene_sky        draws the source behind the opaque meshes
//
// The scene nodes bind the reflection and irradiance cubes through
// environment_bind (scene_target_begin), the surface template lights with
// them. Without an Environment the ambient level of the first Light lights
// uniformly, as gfx's white cubes give.

import "core:math"
import "core:math/linalg"
import gfx "moonhug:libs/gfx"

ENV_SOURCE_SIZE       :: 512 // the sky's face size, what scene_sky shows
ENV_SPECULAR_SIZE     :: 128
ENV_SPECULAR_MIPS     :: 6   // roughness 0, 0.2, .. 1
ENV_IRRADIANCE_SIZE   :: 32
ENV_PREFILTER_SAMPLES :: 64
ENV_IRRADIANCE_LOD    :: 4   // the source mip the irradiance reads (32 px)

// The env_capture shader's property block (shaders/env_capture.frag.glsl).
@(private = "file")
_Capture_Params :: struct {
	face_mode:   [4]f32,
	sky_top:     [4]f32,
	sky_horizon: [4]f32,
	ground:      [4]f32,
	sun_dir:     [4]f32,
	sun_color:   [4]f32,
}

// Everything the cubes depend on: rebuilt when it changes.
@(private = "file")
_Env_Key :: struct {
	params:   _Capture_Params,
	panorama: Asset_GUID,
	has_pano: bool,
}

@(private = "file")
_env: struct {
	source, specular, irradiance: ^gfx.Cubemap,
	key:        _Env_Key,
	built:      bool,
	active:     bool, // an Environment drives this frame
	draw_sky:   bool,
	diffuse:    f32,
	reflection: f32,
}

@(render_node={summary="renders the scene's Environment into cubes for reflections and ambient light, when it changed", frame=true, reads="scene"})
environment_pass :: proc(ctx: ^Render_Ctx) {
	_env.active = false
	env := _active_environment()
	if env == nil do return

	params, pano, has_pano := _capture_params(env)
	key := _Env_Key{params = params, panorama = env.panorama, has_pano = has_pano}
	if !_env.built || key != _env.key {
		if !_env_rebuild(params, pano) do return
		_env.key = key
		_env.built = true
	}
	_env.active = true
	_env.draw_sky = env.draw_sky
	_env.diffuse = env.ambient_intensity
	_env.reflection = env.reflection_intensity
}

// Hands this frame's environment to the current pass (scene_target_begin).
environment_bind :: proc() {
	if !_env.active do return
	gfx.set_environment(_env.specular, _env.irradiance, _env.diffuse, _env.reflection)
}

@(render_node={summary="draws the Environment's sky behind the opaque meshes", reads="hdr", writes="hdr:HDR"})
scene_sky :: proc(ctx: ^Render_Ctx) {
	if !_env.active || !_env.draw_sky do return
	scene_target_begin(ctx)
	inv := linalg.inverse(ctx.view.view_proj)
	sky := gfx.cubemap_texture(_env.source)
	gfx.draw_sky(gfx.SKYBOX_SHADER, []^gfx.Texture{&sky}, (^[size_of(inv)]u8)(&inv)[:])
	gfx.pass_end()
}

_render_environment_shutdown :: proc() {
	gfx.cubemap_destroy(_env.source)
	gfx.cubemap_destroy(_env.specular)
	gfx.cubemap_destroy(_env.irradiance)
	_env = {}
}

// The first enabled Environment on an active object, nil when none.
@(private = "file")
_active_environment :: proc() -> ^Environment {
	w := ctx_world()
	if w == nil do return nil
	it := pool_iterator(environments(w))
	for e in pool_next(&it) {
		if e.enabled && transform_active_in_hierarchy(e.owner) do return e
	}
	return nil
}

// The capture shader's inputs: the sky's colors in linear, the sun from the
// first enabled directional Light, the panorama when its texture loads.
@(private = "file")
_capture_params :: proc(env: ^Environment) -> (p: _Capture_Params, pano: gfx.Texture, has_pano: bool) {
	mode := f32(0)
	switch env.sky {
	case .Procedural: mode = 0
	case .Panorama:   mode = 1
	case .Color:      mode = 2
	}
	pano = gfx.white_texture()
	if env.sky == .Panorama {
		if t, ok := texture_load(env.panorama); ok && env.panorama != {} {
			pano = t.gfx^
			has_pano = true
		} else {
			mode = 0 // no texture yet: the procedural sky stands in
		}
	}
	p.face_mode = {0, mode, math.to_radians(env.panorama_rotation), max(env.exposure, 0)}
	p.sky_top = gfx.srgb_to_linear(env.sky_top)
	p.sky_horizon = gfx.srgb_to_linear(env.sky_horizon)
	p.ground = gfx.srgb_to_linear(env.ground)
	p.sun_dir = {0, 1, 0, 1}
	if sun, ok := _sun(); ok {
		to_sun := linalg.normalize0(-sun.direction)
		p.sun_dir = {to_sun.x, to_sun.y, to_sun.z, math.cos(math.to_radians(max(env.sun_size, 0.01)))}
		c := gfx.srgb_to_linear({sun.color.r, sun.color.g, sun.color.b, 1})
		p.sun_color = {c.r * sun.intensity, c.g * sun.intensity, c.b * sun.intensity, 0}
	}
	return
}

// The first enabled directional Light, as gfx takes it.
@(private = "file")
_sun :: proc() -> (gfx.Light, bool) {
	w := ctx_world()
	if w == nil do return {}, false
	it := pool_iterator(lights(w))
	for l in pool_next(&it) {
		if !l.enabled || l.type != .Directional || !transform_active_in_hierarchy(l.owner) do continue
		return light_to_gfx(l, transform_world(Transform_Handle(l.owner))), true
	}
	return {}, false
}

// Renders the sky into the source cube, then the reflection's mips and the
// irradiance from it. False when the cubes cannot be made (no device).
@(private = "file")
_env_rebuild :: proc(params: _Capture_Params, pano: gfx.Texture) -> bool {
	if _env.source == nil {
		_env.source = gfx.cubemap_create(ENV_SOURCE_SIZE, i32(math.log2(f32(ENV_SOURCE_SIZE))) + 1)
		_env.specular = gfx.cubemap_create(ENV_SPECULAR_SIZE, ENV_SPECULAR_MIPS)
		_env.irradiance = gfx.cubemap_create(ENV_IRRADIANCE_SIZE, 1)
	}
	if _env.source == nil || _env.specular == nil || _env.irradiance == nil do return false

	p := params
	inputs := []gfx.Texture{pano}
	for face in 0 ..< i32(6) {
		p.face_mode.x = f32(face)
		gfx.cubemap_render(_env.source, face, 0, gfx.ENV_CAPTURE_SHADER, inputs, (^[size_of(p)]u8)(&p)[:])
	}
	gfx.cubemap_generate_mips(_env.source)

	source := []gfx.Texture{gfx.cubemap_texture(_env.source)}
	for mip in 0 ..< i32(ENV_SPECULAR_MIPS) {
		rough := f32(mip) / f32(ENV_SPECULAR_MIPS - 1)
		for face in 0 ..< i32(6) {
			q := [4]f32{f32(face), rough, ENV_SOURCE_SIZE, ENV_PREFILTER_SAMPLES}
			gfx.cubemap_render(_env.specular, face, mip, gfx.ENV_PREFILTER_SHADER, source, (^[size_of(q)]u8)(&q)[:])
		}
	}
	for face in 0 ..< i32(6) {
		q := [4]f32{f32(face), ENV_IRRADIANCE_LOD, 0, 0}
		gfx.cubemap_render(_env.irradiance, face, 0, gfx.ENV_IRRADIANCE_SHADER, source, (^[size_of(q)]u8)(&q)[:])
	}
	return true
}
