package engine

// Volume: a place where render steps run with other settings
// (plugins/engine/docs/RenderPipeline.md "Volumes"): the tonemap's grading in
// a cave, the exposure's limits outdoors. A global volume applies to every
// view, a local one to a view whose camera is inside its box, fading in
// over `blend_distance` outside it. Several volumes blend in priority order
// (render_volumes.odin).

// One step's settings as the volume wants them: the whole block, as JSON
// (the Volume inspector writes it through the step's settings drawer).
// Empty text is the step's defaults.
Volume_Override :: struct {
	step:     string, // a render step's name (render_step_find)
	settings: string, // owned
}

@(component={max=64, menu="Rendering/Volume"})
@(typ_guid={guid = "b3ac006d-03a0-4f97-8040-56f373894b95"})
Volume :: struct {
	using base: CompData `inspect:"-"`,
	// Everywhere, whatever the camera's position. Otherwise inside the box.
	global:         bool,
	// The box, around the transform, in its space: its scale scales the box.
	size:           [3]f32 `decor:min(0)`,
	// World units outside the box over which the volume fades in: 0 switches
	// at the edge.
	blend_distance: f32 `decor:min(0)`,
	// How much of its overrides apply at full strength.
	weight:         f32 `decor:range(0, 1)`,
	// A higher priority blends in later, over lower ones.
	priority:       i32,
	overrides:      [dynamic]Volume_Override `inspect:"-"`,
}

reset_Volume :: proc(v: ^Volume) {
	cleanup_Volume(v)
	v.global = false
	v.size = {10, 10, 10}
	v.blend_distance = 1
	v.weight = 1
	v.priority = 0
}

cleanup_Volume :: proc(v: ^Volume) {
	for &o in v.overrides {
		delete(o.step)
		delete(o.settings)
	}
	delete(v.overrides)
	v.overrides = nil
}
