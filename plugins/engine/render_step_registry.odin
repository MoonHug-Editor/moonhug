package engine

// The render step registry: the steps a render pipeline places
// (render_pipeline.odin, plugins/engine/docs/RenderPipeline.md).
//
// A step is a proc declared with @(render_step). It declares the targets
// it reads and writes, whether it runs per frame or per view, and its
// settings struct. The prebuild (gen/render_step_gen.odin) checks the
// declarations and emits the registrations, so a bad declaration is a build
// error. Which steps run, and in what order, is the pipeline asset's: the
// registry only says what exists.
//
// A step records its GPU passes through gfx (none, one or several), takes the targets
// it declared from the view's pool (render_target), reads earlier steps' by
// name (render_input), and never knows which other steps exist.
//
// Steps register from two generated files, since the app binary cannot
// import an editor package: runtime steps from <runnable>/render_steps_generated.odin
// (called by __standalone_run), every step from the engine's scene tools
// for the editor (@(init)).

import "base:runtime"
import "core:fmt"
import "core:strings"
import gfx "moonhug:libs/gfx"

// What one run of a pipeline works on: the view, where it draws, the targets
// steps share by name, and the commands collected for the view before the
// pipeline ran (render_collect_commands), so every step sees the same list.
Render_Ctx :: struct {
	view:     Render_View,
	target:   ^gfx.Render_Target, // nil = the swapchain (the app's window)
	pool:     ^gfx.Target_Pool,   // the view's named targets, sized to the view
	commands: []Render_Command,
	clear:    Maybe([4]f32),      // the camera's clear color, nil keeps what an earlier camera drew
	// The pool target holding the finished image so far, what final_blit
	// copies to the view's target: the last target a step took with
	// render_target that its declaration marks final (`hdr:HDR*`). A step
	// reads it as "final" (render_input).
	final:    string,
	step:     ^Render_Step, // the step running, set by render_pipeline_run
	settings: rawptr,       // this instance's settings struct (the step's `settings=` type), nil when it has none
	// This instance's ports after the pipeline's bindings, parallel to
	// step.reads and step.writes: the names render_input and render_target use.
	reads:    []string,
	writes:   []Render_Target_Decl,
	// What the host draws into the scene, with the view's view_proj set:
	// `overlay_under` after the opaques (the editor's grid), `overlay_over`
	// after the whole scene (gizmos, the app's DebugDraw phase), each from its
	// own step (scene_under, scene_over). Both share the scene's depth, so a
	// grid line hides behind a mesh and a gizmo can test against it.
	overlay_under: proc(),
	overlay_over:  proc(),
	// The editor's scene view: the run the Render Pipeline window inspects
	// first, and the one "Show in scene view" replaces the image of.
	scene_view: bool,
	// The view's scene depth holds the opaque meshes already (depth_prepass
	// ran in this run): scene_opaque keeps it instead of clearing it.
	depth_primed: bool,
	// This view's directional shadow cascades (shadow_cascades), bound by
	// scene_target_begin. count 0 = none this run.
	shadow_cascades: gfx.Shadow_Cascades,
	// This run's sub-pixel camera offset in clip space (render_taa.odin): the
	// scene steps draw through render_draw_view, which applies it, until
	// scene_taa resolves and clears it. Zero = the steady camera.
	jitter: [2]f32,
	// The view targets steps took this run (render_target), temp-allocated:
	// what render_input finds. A target a step did not take this run is
	// absent, even though the pool still holds last frame's texture.
	taken: [dynamic]string,
}

// The named-target pool of a view, keyed by its render target (nil for the
// swapchain). Pools live until engine shutdown, since a view's targets are
// reused every frame and freed only with the engine.
render_view_pool :: proc(target: ^gfx.Render_Target) -> ^gfx.Target_Pool {
	context.allocator = runtime.default_allocator()
	if _view_pools == nil do _view_pools = make(map[^gfx.Render_Target]^gfx.Target_Pool)
	if p, ok := _view_pools[target]; ok do return p
	p := new(gfx.Target_Pool)
	_view_pools[target] = p
	return p
}

// Frees every view pool. Called at engine shutdown (lifecycle.odin), and by
// whoever destroys a render target that had a pool.
render_view_pool_destroy :: proc(target: ^gfx.Render_Target) {
	if p, ok := _view_pools[target]; ok {
		gfx.pool_destroy(p)
		free(p, runtime.default_allocator())
		delete_key(&_view_pools, target)
	}
}

_render_view_pools_shutdown :: proc() {
	for _, p in _view_pools {
		gfx.pool_destroy(p)
		free(p, runtime.default_allocator())
	}
	delete(_view_pools)
	_view_pools = nil
	gfx.pool_destroy(&_frame_pool)
	_frame_taken_shutdown()
	_render_inspect_shutdown()
	_render_pipeline_shutdown()
	_render_environment_shutdown()
	_render_taa_shutdown()
	_render_ssr_shutdown()
	_render_volumes_shutdown()
}

@(private = "file")
_view_pools: map[^gfx.Render_Target]^gfx.Target_Pool

// Runs a step: records its GPU passes, none, one or several, for the view in `ctx`.
// The step's name is the proc's name, unique across installed packages: it
// is what a pipeline asset places. `summary` is one short line of what the
// step does, shown on its block in the pipeline window.
//
// Settings. `settings="var"` names a package-level var of the step's
// settings struct holding its defaults. Each placed instance gets its own
// copy, edited in the pipeline window and stored in the asset, and the step
// reads it as `(^T)(ctx.settings)`.
//
// Targets. `writes` declares each target the step renders, as
// `name[:FORMAT][@scale|@Npx][*]`: FORMAT is LDR (default) or HDR, `@0.5`
// sizes it to a fraction of the view (default 1), `@2048px` to fixed pixels
// (required on a per-frame step), `*` makes it the view's final image when
// the step takes it. The step takes the target with render_target(ctx, name),
// which allocates it from the declaration. Two steps that write one name
// declare it the same way. `reads` names the targets the step samples, taken
// with render_input(ctx, name): a target of this view, a per-frame step's, or
// `final`, the finished image so far. `scene` names the view's objects (the
// commands collected for it): a step that draws them reads `scene`, which
// is always available and is not a texture (render_input returns nil).
// A read ending in `?` is optional: the step works without it (no shadows,
// no ambient occlusion, no bloom), so a pipeline where nothing before the
// step writes it loads without a warning, and render_input returns nil.
// Everything a step uses from another step goes through a declared read:
// that is what the pipeline checks and the window shows.
//
// `frame=true` makes a per-frame step: it does not read the view, so it runs
// once per frame before any view's steps, however many views run the pipeline
// (a directional shadow map, a probe). It gets the frame's pool, not a view's,
// and its ctx has no commands, target or clear: it collects what it needs.
@(extension_point={attribute="render_step", target="proc", fields="summary reads writes frame settings"})
Render_Step_Proc :: proc(ctx: ^Render_Ctx)

// One declared write of a step: what render_target allocates for the name.
Render_Target_Decl :: struct {
	name:   string,
	format: gfx.Target_Format,
	scale:  f32,  // of the view's size, when px is 0
	px:     i32,  // fixed size in pixels (square), or 0
	final:  bool, // taking it makes it the view's final image (ctx.final)
}

// The name a read uses for the finished image so far (ctx.final).
FINAL_INPUT :: "final"

// The name a read uses for the view's objects: what a step that draws the
// scene reads. Not a texture, it comes from outside the frame.
SCENE_INPUT :: "scene"

Render_Step :: struct {
	name:    string,
	pkg:     string,   // the package that declares it, for the pipeline window
	summary: string,   // one line of what it does, for the pipeline window
	file:    string,   // where the proc is declared, repo-relative, for the window's jump to code
	line:    int,
	frame:  bool,     // per-frame step: once per frame, before any view's steps
	reads:  []string, // target names, as declared
	// Parallel to reads, nil when none is: read declared with a trailing
	// `?`, which the step works without.
	optional: []bool,
	writes: []Render_Target_Decl,
	run:    Render_Step_Proc,
	// The settings struct: its typeid, the typeid of a pointer to it (what
	// json.unmarshal_any wants), its size, and the declared defaults.
	settings_tid:     typeid,
	settings_ptr_tid: typeid,
	settings_size:    int,
	settings_default: rawptr,
}

// The target the running step declared as `name` (the declared name, the
// pipeline may have bound it to another), allocated from the declaration in
// the step's pool: the view's size times the declared scale, or the declared
// pixels. A name the step does not declare is the step's bug. Marks the
// view's final image when the declaration says so, so a step that skips its
// work (an effect turned off) leaves the earlier final.
// `mips` gives the target a mip chain (gfx.rt_create): for one that is
// copied into and sampled minified.
render_target :: proc(ctx: ^Render_Ctx, name: string, mips := false) -> ^gfx.Render_Target {
	assert(ctx.step != nil, "render_target outside a render step")
	for decl, i in ctx.step.writes {
		if decl.name != name do continue
		d := i < len(ctx.writes) ? ctx.writes[i] : decl
		w, h := d.px, d.px
		if d.px == 0 {
			w = max(i32(ctx.view.width * d.scale), 1)
			h = max(i32(ctx.view.height * d.scale), 1)
		}
		rt := gfx.pool_target(ctx.pool, d.name, w, h, d.format, mips)
		if d.final do ctx.final = d.name
		_mark_taken(ctx, d.name)
		return rt
	}
	panic(fmt.tprintf("render step %s takes target %q without declaring it in writes=", ctx.step.name, name))
}

// A target the running step declared in reads= (the declared name, the
// pipeline may have bound it to another): `final` is the finished image so
// far, any other name is the view's target of that name, or a per-frame
// step's. nil when no step rendered it this frame (the writer skipped its
// work), which the reader treats as absent.
render_input :: proc(ctx: ^Render_Ctx, name: string) -> ^gfx.Render_Target {
	assert(ctx.step != nil, "render_input outside a render step")
	name := name
	declared := false
	for r, i in ctx.step.reads {
		if r != name do continue
		declared = true
		if i < len(ctx.reads) do name = ctx.reads[i]
	}
	if !declared do panic(fmt.tprintf("render step %s reads target %q without declaring it in reads=", ctx.step.name, name))
	if name == SCENE_INPUT do return nil
	if name == FINAL_INPUT {
		if ctx.final == "" do return nil
		return gfx.pool_find(ctx.pool, ctx.final)
	}
	if !ctx.step.frame {
		for t in ctx.taken do if t == name do return gfx.pool_find(ctx.pool, name)
	}
	if _frame_taken[name] == gfx.frame_index + 1 do return gfx.pool_find(&_frame_pool, name)
	return nil
}

// Records that the running step took `name` this run: a view target into
// the ctx, a frame target into the frame's set (stored +1 so frame 0 counts),
// and for the Render Pipeline window, into the instance being inspected.
@(private = "file")
_mark_taken :: proc(ctx: ^Render_Ctx, name: string) {
	if ctx.step.frame {
		if name not_in _frame_taken {
			_frame_taken[strings.clone(name, runtime.default_allocator())] = 0
		}
		_frame_taken[name] = gfx.frame_index + 1
	} else {
		if ctx.taken == nil do ctx.taken = make([dynamic]string, context.temp_allocator)
		append(&ctx.taken, name)
	}
	_inspect_taken(name)
}

// The frame targets per-frame steps took, with gfx.frame_index + 1 of the
// last time. Keys are cloned on the default allocator: the names belong to
// pipeline instances, which a rebuild frees.
@(private = "file")
_frame_taken: map[string]u64

_frame_taken_shutdown :: proc() {
	for k in _frame_taken do delete(k, runtime.default_allocator())
	delete(_frame_taken)
	_frame_taken = nil
}

// Process-lifetime registry on the default allocator: registration runs from
// @(init) procs in generated files and must not capture their context.
_render_steps: [dynamic]Render_Step

@(init)
_render_steps_init :: proc "contextless" () {
	context = runtime.default_context()
	_render_steps = make([dynamic]Render_Step, runtime.default_allocator())
	_frame_taken = make(map[string]u64, runtime.default_allocator())
}

// Whether read `i` of the step is optional (declared `name?`).
render_step_read_optional :: proc(step: ^Render_Step, i: int) -> bool {
	return i < len(step.optional) && step.optional[i]
}

// Whether the running step declares a read of `name` (as declared, before
// the pipeline's bindings): for shared helpers that serve several steps, such
// as scene_target_begin, which binds the shadows and the ambient occlusion
// only for a step that reads them.
render_reads :: proc(ctx: ^Render_Ctx, name: string) -> bool {
	assert(ctx.step != nil, "render_reads outside a render step")
	for r in ctx.step.reads do if r == name do return true
	return false
}

// Adds a step. Called by the generated registrations.
render_step_register :: proc(step: Render_Step) {
	context.allocator = runtime.default_allocator()
	if existing := render_step_find(step.name); existing != nil {
		panic(fmt.tprintf("render step %s is registered twice (packages %s and %s)", step.name, existing.pkg, step.pkg))
	}
	append(&_render_steps, step)
}

render_step_find :: proc(name: string) -> ^Render_Step {
	for &n in _render_steps do if n.name == name do return &n
	return nil
}

// Every registered step, in registration order: the pipeline window's palette.
render_steps :: proc() -> []Render_Step {
	return _render_steps[:]
}

// The frame's named targets, shared by every view (per-frame steps write
// them, view steps read them).
render_frame_pool :: proc() -> ^gfx.Target_Pool {
	return &_frame_pool
}

@(private = "file")
_frame_pool: gfx.Target_Pool

