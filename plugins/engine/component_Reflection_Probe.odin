package engine

// Reflection Probe: a place whose surroundings are captured into a cube, so
// smooth surfaces near it reflect the room instead of the sky alone
// (plugins/engine/docs/Materials.md "Reflection probes"). The probe's box,
// around its transform's position and aligned to the world, says which
// meshes use it: a mesh whose centre lies inside takes the smallest such
// box's cube in place of the scene's Environment for its reflections, and
// with `diffuse` on, the captured room's diffuse light in place of the
// Environment's too. Within `blend_distance` of the box's edge a mesh
// fades into the next smaller box holding it, or the Environment. The
// frame lane's reflection_probes_pass step captures it (render_probes.odin).

// When the cube is captured again.
Probe_Refresh :: enum u8 {
	Once,        // when the probe is first seen, and when it moves or its settings change
	Every_Frame, // each frame: moving objects show, at six scene renders a frame
}

// One face's size in pixels.
Probe_Resolution :: enum u8 {
	Res_64,
	Res_128,
	Res_256,
}

@(component={max=32, menu="Rendering/Reflection Probe"})
@(typ_guid={guid = "8909eabd-746b-4bfd-b405-e3a34003d0b9"})
Reflection_Probe :: struct {
	using base: CompData `inspect:"-"`,
	// The box, in world units around the transform's position, aligned to
	// the world: the meshes inside reflect this probe.
	size:           [3]f32 `decor:min(0)`,
	// How far inside the box's edge a mesh starts fading into the next
	// smaller box holding it, or the Environment, in world units: 0 switches
	// at the edge. Neighbouring rooms' boxes overlap by it to crossfade.
	blend_distance: f32 `decor:min(0)`,
	// Reflect the box's walls where they are (a floor shows the room at
	// its place) instead of at infinity, as fits a room. Off for open
	// ground, where there are no walls to project onto.
	box_projection: bool,
	// Light the meshes inside with the room's diffuse light as captured
	// (its walls, floor and lights) instead of the Environment's sky, so
	// they stop looking lit from outdoors.
	diffuse:        bool,
	// How bright the reflection and the diffuse light are.
	intensity:      f32 `decor:min(0)`,
	resolution:     Probe_Resolution,
	refresh:        Probe_Refresh,
}

reset_Reflection_Probe :: proc(p: ^Reflection_Probe) {
	p.size = {10, 10, 10}
	p.blend_distance = 1
	p.box_projection = true
	p.diffuse = true
	p.intensity = 1
	p.resolution = .Res_128
	p.refresh = .Once
}
