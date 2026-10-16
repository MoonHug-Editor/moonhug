package engine

import gfx "moonhug:libs/gfx"

// The scene's environment: the sky behind the cameras and the light it
// gives everything no light reaches, diffuse (ambient) and specular
// (reflections), rendered into cubes by render_environment.odin
// (plugins/engine/docs/Materials.md "Environment"). The first enabled one
// in the world drives the scene. Without one, the first Light's ambient
// level lights uniformly and nothing is reflected.

Environment_Sky :: enum u8 {
	Procedural, // a gradient from the ground through the horizon to the zenith, with the sun
	Panorama,   // an equirectangular texture (2:1, longitude across, latitude down)
	Color,      // one color, the sky top's
}

@(component={max=4, menu="Rendering/Environment"})
@(typ_guid={guid = "9d79f55a-e5ac-4e37-a2bf-12c807ec781e"})
Environment :: struct {
	using base: CompData `inspect:"-"`,
	sky:                  Environment_Sky,
	sky_top:              [4]f32 `decor:color()`, // the zenith, and the Color sky's color
	sky_horizon:          [4]f32 `decor:color()`,
	ground:               [4]f32 `decor:color()`,
	// The sun disc's angular radius in degrees. The sun is the first enabled
	// directional Light: its direction and color.
	sun_size:             f32 `decor:min(0)`,
	panorama:             Asset_GUID `ext:"png,jpg,jpeg,bmp,hdr"`, // an .hdr is linear light, other images are sRGB color
	panorama_rotation:    f32, // degrees around the vertical
	exposure:             f32 `decor:min(0)`, // the sky's brightness
	ambient_intensity:    f32 `decor:min(0)`, // how much the sky lights surfaces (diffuse)
	reflection_intensity: f32 `decor:min(0)`, // how much surfaces reflect it (specular)
	draw_sky:             bool, // shown behind the cameras (else their clear color stays)
	fog:                  Environment_Fog,
}

// Fog over the scene (gfx.Fog): every material fades toward the colour with
// its distance to the camera, the sky by direction.
Environment_Fog :: struct {
	mode:           gfx.Fog_Mode,
	color:          [4]f32 `decor:color()`,
	// The exponential modes: per world unit.
	density:        f32 `decor:min(0)`,
	// Linear: no fog before start, all of it at end, world units.
	start:          f32 `decor:min(0)`,
	end:            f32 `decor:min(0)`,
	// Height fog: full density below `height`, falling off above it by
	// exp(-height_falloff * height above). 0 falloff is the same fog at
	// every height.
	height:         f32,
	height_falloff: f32 `decor:min(0)`,
	// How much of the fog the sky takes at the horizon, none straight up.
	sky:            f32 `decor:range(0, 1)`,
}

ENVIRONMENT_FOG_DEFAULT :: Environment_Fog{color = {0.7, 0.75, 0.8, 1}, density = 0.02, start = 10, end = 100, sky = 0.5}

reset_Environment :: proc(e: ^Environment) {
	e.sky = .Procedural
	e.sky_top = {0.35, 0.55, 0.85, 1}
	e.sky_horizon = {0.75, 0.82, 0.9, 1}
	e.ground = {0.35, 0.32, 0.3, 1}
	e.sun_size = 1
	e.fog = ENVIRONMENT_FOG_DEFAULT
	e.exposure = 1
	e.ambient_intensity = 1
	e.reflection_intensity = 1
	e.draw_sky = true
}
