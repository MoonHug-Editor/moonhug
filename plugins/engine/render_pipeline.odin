package engine

// The render pipeline: the frame as an asset (plugins/engine/docs/RenderPipeline.md).
//
// A `.renderpipeline` asset lists the nodes a frame runs: the per-frame
// nodes once, then one lane per slot. A camera names a slot (Camera.slot,
// "Main" by default) and renders through that lane. The project's active
// pipeline is the Rendering project setting, the essentials plugin's
// Default.renderpipeline when unset, and a built-in frame when neither
// exists, so the engine renders with no asset installed.
//
// A node is a proc declared with @(render_node) (render_node_registry.odin): the
// registry of what can be placed. The asset places instances of them, each
// with its own settings and port bindings, in the order the pipeline window
// lists them: a lane runs its nodes in the order they appear in `nodes`.
// Nothing is sorted: what you see is what runs.
//
// A placed node's ports are bound by name: a read takes the target of that
// name from the pool, a write creates it. The declared names are the
// defaults, and an entry may rebind a port (`binds`), so two blooms in one
// lane write `bloom` and `bloom_wide` and a tonemap picks which it reads.
// That is the whole wiring: a sequence with named ports carries the same
// information as a wired graph, laid out one way.
//
// Validation happens when a pipeline loads: a read no earlier node writes
// and an instance naming a node that is not installed (a removed plugin)
// are each warned once and the frame still renders, since both are the
// asset's business and not an engine invariant.

import "base:runtime"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import "core:os"
import "core:strings"
import gfx "moonhug:libs/gfx"
import "moonhug:libs/log"
import "moonhug:libs/serialization"

// The slot a camera renders through when it names none, and the slot the
// editor's scene view prefers (falling back to MAIN_SLOT).
MAIN_SLOT   :: "Main"
EDITOR_SLOT :: "Editor"

// One placed node: `node` names the registered @(render_node) proc, `slot`
// the lane ("" = the per-frame lane), `binds` the ports whose target differs
// from the declared name, `settings` the values of the node's settings struct
// as JSON (absent keys keep the node's defaults).
Pipeline_Entry :: struct {
	id:       i32,
	node:     string,
	slot:     string,
	muted:    bool, // placed but skipped: the frame runs as if it were not there
	binds:    [dynamic]Pipeline_Bind,
	settings: json.Value,
}

// A port of a placed node bound to another target name than it declares.
// `port` is the declared name (a read or a write of the node), `target` the
// pool name it uses instead. A read may bind to "final".
Pipeline_Bind :: struct {
	port:   string,
	target: string,
}

Pipeline_Slot :: struct {
	name: string,
}

@(typ_guid={guid = "6b1f3c2e-7d4a-4e85-9c0b-2a5f8d1e4c73", menu_assets_create = {menu_name = "Render Pipeline", file_name = "New Render Pipeline.renderpipeline", order = -4}})
Render_Pipeline :: struct {
	slots:   [dynamic]Pipeline_Slot,
	nodes:   [dynamic]Pipeline_Entry,
	next_id: i32,
}

// A new pipeline: the engine's frame on one Main slot. What the Create menu
// writes, and the built-in frame when no asset is installed.
reset_Render_Pipeline :: proc(p: ^Render_Pipeline) {
	cleanup_Render_Pipeline(p)
	p.next_id = 1
	pipeline_add_slot(p, MAIN_SLOT)
	pipeline_add_node(p, "environment_pass", "")
	pipeline_add_node(p, "shadow_pass", "")
	for name in ([]string{"scene_opaque", "scene_sky", "scene_under", "scene_transparent", "scene_over", "final_blit"}) {
		pipeline_add_node(p, name, MAIN_SLOT)
	}
}

cleanup_Render_Pipeline :: proc(p: ^Render_Pipeline) {
	for s in p.slots do delete(s.name)
	delete(p.slots)
	for &e in p.nodes do pipeline_entry_destroy(&e)
	delete(p.nodes)
	p^ = {}
}

pipeline_entry_destroy :: proc(e: ^Pipeline_Entry) {
	delete(e.node)
	delete(e.slot)
	for b in e.binds {
		delete(b.port)
		delete(b.target)
	}
	delete(e.binds)
	json.destroy_value(e.settings)
	e^ = {}
}

// The target a port of the entry uses: its binding, or the declared name.
pipeline_entry_port :: proc(e: Pipeline_Entry, port: string) -> string {
	for b in e.binds do if b.port == port do return b.target
	return port
}

// Binds a port to `target`, or unbinds it when `target` is "" or the declared name.
pipeline_entry_bind :: proc(e: ^Pipeline_Entry, port: string, target: string) {
	for b, i in e.binds {
		if b.port != port do continue
		if target == "" || target == port {
			delete(b.port)
			delete(b.target)
			ordered_remove(&e.binds, i)
		} else {
			delete(e.binds[i].target)
			e.binds[i].target = strings.clone(target)
		}
		return
	}
	if target == "" || target == port do return
	append(&e.binds, Pipeline_Bind{port = strings.clone(port), target = strings.clone(target)})
}

pipeline_add_slot :: proc(p: ^Render_Pipeline, name: string) -> bool {
	if name == "" || pipeline_find_slot(p, name) do return false
	append(&p.slots, Pipeline_Slot{name = strings.clone(name)})
	return true
}

pipeline_find_slot :: proc(p: ^Render_Pipeline, name: string) -> bool {
	for s in p.slots do if s.name == name do return true
	return false
}

// Removes a slot and every node placed in it.
pipeline_remove_slot :: proc(p: ^Render_Pipeline, name: string) {
	for i := len(p.nodes) - 1; i >= 0; i -= 1 {
		if p.nodes[i].slot == name {
			pipeline_entry_destroy(&p.nodes[i])
			ordered_remove(&p.nodes, i)
		}
	}
	for s, i in p.slots {
		if s.name == name {
			delete(s.name)
			ordered_remove(&p.slots, i)
			return
		}
	}
}

// Places a node in its lane: at the end, or at `index` within the lane
// (0 = first). The entry is inserted into `nodes` right where that lane
// position falls, so array order and lane order agree.
pipeline_add_node :: proc(p: ^Render_Pipeline, node: string, slot: string, index := -1) -> i32 {
	if p.next_id < 1 do p.next_id = 1
	e := Pipeline_Entry{id = p.next_id, node = strings.clone(node), slot = strings.clone(slot)}
	p.next_id += 1
	at := _lane_insert_at(p, slot, index)
	inject_at(&p.nodes, at, e)
	return e.id
}

// Moves a placed node to `slot` at lane position `index` (-1 = the end).
pipeline_move_node :: proc(p: ^Render_Pipeline, id: i32, slot: string, index := -1) -> bool {
	from := -1
	for e, i in p.nodes do if e.id == id do from = i
	if from < 0 do return false
	e := p.nodes[from]
	ordered_remove(&p.nodes, from)
	if e.slot != slot {
		delete(e.slot)
		e.slot = strings.clone(slot)
	}
	at := _lane_insert_at(p, slot, index)
	inject_at(&p.nodes, at, e)
	return true
}

// The nodes of one lane, in order (temp-allocated pointers into `nodes`).
pipeline_lane :: proc(p: ^Render_Pipeline, slot: string) -> []^Pipeline_Entry {
	out := make([dynamic]^Pipeline_Entry, context.temp_allocator)
	for &e in p.nodes do if e.slot == slot do append(&out, &e)
	return out[:]
}

// The array index at which a node inserted at lane position `index` goes:
// before the lane's `index`-th node, or after the lane's last one (or at the
// array's end when the lane is empty).
@(private = "file")
_lane_insert_at :: proc(p: ^Render_Pipeline, slot: string, index: int) -> int {
	seen, last := 0, -1
	for e, i in p.nodes {
		if e.slot != slot do continue
		if index >= 0 && seen == index do return i
		seen += 1
		last = i
	}
	return last + 1 if last >= 0 else len(p.nodes)
}

pipeline_find_node :: proc(p: ^Render_Pipeline, id: i32) -> ^Pipeline_Entry {
	for &e in p.nodes do if e.id == id do return &e
	return nil
}

pipeline_remove_node :: proc(p: ^Render_Pipeline, id: i32) {
	for &e, i in p.nodes {
		if e.id == id {
			pipeline_entry_destroy(&e)
			ordered_remove(&p.nodes, i)
			return
		}
	}
}

pipeline_load_file :: proc(path: string) -> (p: Render_Pipeline, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return {}, false
	return pipeline_parse(data)
}

pipeline_parse :: proc(data: []u8) -> (p: Render_Pipeline, ok: bool) {
	if json.unmarshal(data, &p, .JSON, context.allocator) != nil {
		cleanup_Render_Pipeline(&p)
		return {}, false
	}
	return p, true
}

pipeline_save_file :: proc(p: ^Render_Pipeline, path: string, guid: Asset_GUID) -> bool {
	return serialization.write_asset_to_path(path, uuid.Identifier(guid), p^)
}

// A deep copy, for the runtime's own copy of the asset. Each entry is copied
// whole and then its owned fields are replaced by copies, so a field added
// to Pipeline_Entry is carried without touching this proc.
pipeline_clone :: proc(src: Render_Pipeline) -> (p: Render_Pipeline) {
	p.next_id = src.next_id
	for s in src.slots do append(&p.slots, Pipeline_Slot{name = strings.clone(s.name)})
	for e in src.nodes {
		c := e
		c.node = strings.clone(e.node)
		c.slot = strings.clone(e.slot)
		c.settings = _json_clone(e.settings)
		c.binds = nil
		for b in e.binds do append(&c.binds, Pipeline_Bind{port = strings.clone(b.port), target = strings.clone(b.target)})
		append(&p.nodes, c)
	}
	return p
}

@(private = "file")
_json_clone :: proc(v: json.Value) -> json.Value {
	if v == nil do return nil
	bytes, merr := json.marshal(v, {spec = .JSON}, context.temp_allocator)
	if merr != nil do return nil
	out, perr := json.parse(bytes, .JSON, true)
	if perr != nil do return nil
	return out
}

// ---------------------------------------------------------------------------
// The active pipeline, as the frame runs it.

// The Rendering project setting: which pipeline asset the project renders
// through. Unset = the essentials plugin's Default.renderpipeline, or the
// built-in frame when that is not installed either.
Rendering_Settings :: struct {
	pipeline: Asset_GUID `ref:"renderpipeline"`,
}

@(project_settings={name="Rendering"})
rendering_settings: Rendering_Settings

// The pipeline asset a project renders through when its Rendering setting
// names none: the essentials plugin sets it to its Default.renderpipeline
// at EngineInit. Empty = the built-in frame.
render_pipeline_default: Asset_GUID

// One placed node as it runs: the registered node, this instance's settings
// (a copy of the node's defaults with the entry's JSON applied) and its ports
// after binding, parallel to the node's declared reads and writes.
Pipeline_Instance :: struct {
	id:       i32,
	node:     ^Render_Node,
	settings: rawptr, // settings_size bytes on the default allocator, nil when the node has none
	muted:    bool,
	reads:    []string,
	writes:   []Render_Target_Decl,
}

Pipeline_Runtime :: struct {
	guid:  Asset_GUID, // {} = the built-in frame
	src:   Render_Pipeline,
	frame: [dynamic]Pipeline_Instance,
	slots: map[string][dynamic]Pipeline_Instance,
}

@(private = "file") _active: Pipeline_Runtime
@(private = "file") _active_built: bool
@(private = "file") _settings_loaded: bool
@(private = "file") _warned_slots: map[string]bool
@(private = "file") _frame_ran: map[i32]u64 // instance id -> gfx.frame_index of its last run

// The pipeline the project renders through, built on first use and rebuilt
// when the Rendering setting names another asset.
render_pipeline_active :: proc() -> ^Pipeline_Runtime {
	context.allocator = runtime.default_allocator()
	if !_settings_loaded {
		_settings_loaded = true
		project_settings_load("Rendering", &rendering_settings)
	}
	want := rendering_settings.pipeline
	if want == {} && render_pipeline_default != {} {
		if _, installed := asset_db_get_path(uuid.Identifier(render_pipeline_default)); installed do want = render_pipeline_default
	}
	if _active_built && _active.guid == want do return &_active
	_pipeline_runtime_destroy(&_active)
	src, ok := _pipeline_asset_load(want)
	if !ok {
		if want != {} do log.warningf("[Render] the Rendering setting names no readable .renderpipeline, using the built-in frame")
		reset_Render_Pipeline(&src)
		want = {}
	}
	_active = _pipeline_runtime_build(src, want)
	_active_built = true
	return &_active
}

// Editor hook: a pipeline document's current values replace the active
// pipeline when it is the one the project renders through, so edits in the
// window change the frame as they are made (material_preview's twin).
render_pipeline_preview :: proc(guid: Asset_GUID, p: Render_Pipeline) {
	context.allocator = runtime.default_allocator()
	active := render_pipeline_active()
	if active.guid != guid do return
	_pipeline_runtime_destroy(&_active)
	_active = _pipeline_runtime_build(pipeline_clone(p), guid)
	_active_built = true
}

// The asset file changed on disk or went away: rebuild from it next frame.
@(init)
_pipeline_evict_hook_register :: proc "contextless" () {
	context = runtime.default_context()
	asset_db_add_evict_hook(_pipeline_path_changed)
	_frame_ran = make(map[i32]u64, runtime.default_allocator())
	_warned_slots = make(map[string]bool, runtime.default_allocator())
}

@(private = "file")
_pipeline_path_changed :: proc(path: string) {
	if !strings.has_suffix(path, ".renderpipeline") do return
	if guid, ok := asset_db_get_guid(path); ok && _active_built && _active.guid == Asset_GUID(guid) {
		_active_built = false // rebuilt from the file on next use
	}
}

_render_pipeline_shutdown :: proc() {
	context.allocator = runtime.default_allocator()
	_pipeline_runtime_destroy(&_active)
	_active_built = false
	_settings_loaded = false
	delete(_frame_ran)
	_frame_ran = nil
	for k in _warned_slots do delete(k)
	delete(_warned_slots)
	_warned_slots = nil
}

@(private = "file")
_pipeline_asset_load :: proc(guid: Asset_GUID) -> (Render_Pipeline, bool) {
	if guid == {} do return {}, false
	path, ok := asset_db_get_path(uuid.Identifier(guid))
	if !ok do return {}, false
	return pipeline_load_file(path)
}

@(private = "file")
_pipeline_runtime_destroy :: proc(r: ^Pipeline_Runtime) {
	destroy_lane :: proc(lane: ^[dynamic]Pipeline_Instance) {
		for inst in lane {
			if inst.settings != nil do free(inst.settings)
			for r in inst.reads do delete(r)
			delete(inst.reads)
			for w in inst.writes do delete(w.name)
			delete(inst.writes)
		}
		delete(lane^)
	}
	destroy_lane(&r.frame)
	for name, &lane in r.slots {
		destroy_lane(&lane)
		delete(name)
	}
	delete(r.slots)
	cleanup_Render_Pipeline(&r.src)
	r^ = {}
}

// Resolves every entry to its node, builds each instance's settings and
// bound ports, keeps each lane in asset order, and warns once per load about
// what will not run as listed.
@(private = "file")
_pipeline_runtime_build :: proc(src: Render_Pipeline, guid: Asset_GUID) -> (r: Pipeline_Runtime) {
	r.guid = guid
	r.src = src
	r.slots = make(map[string][dynamic]Pipeline_Instance)
	for s in src.slots do r.slots[strings.clone(s.name)] = make([dynamic]Pipeline_Instance)

	for e in src.nodes {
		node := render_node_find(e.node)
		if node == nil {
			log.warningf("[Render] pipeline node %q is not installed, skipped (a plugin's node whose link is gone?)", e.node)
			continue
		}
		if e.slot != "" && e.slot not_in r.slots {
			log.warningf("[Render] pipeline node %q sits in slot %q, which the pipeline does not declare, skipped", e.node, e.slot)
			continue
		}
		if node.frame != (e.slot == "") {
			log.warningf("[Render] pipeline node %q is %s and cannot sit in %s, skipped", e.node, node.frame ? "per frame" : "per view", e.slot == "" ? "the frame lane" : "a slot")
			continue
		}
		inst := Pipeline_Instance{id = e.id, node = node, muted = e.muted, settings = _instance_settings(node, e.settings)}
		inst.reads = make([]string, len(node.reads))
		for t, i in node.reads do inst.reads[i] = strings.clone(pipeline_entry_port(e, t))
		inst.writes = make([]Render_Target_Decl, len(node.writes))
		for d, i in node.writes {
			inst.writes[i] = d
			inst.writes[i].name = strings.clone(pipeline_entry_port(e, d.name))
		}
		if e.slot == "" do append(&r.frame, inst)
		else do append(&r.slots[e.slot], inst)
	}
	_pipeline_check_reads(&r)
	return r
}


// A copy of the node's defaults with the entry's JSON applied over it.
@(private = "file")
_instance_settings :: proc(node: ^Render_Node, v: json.Value) -> rawptr {
	if node.settings_size == 0 do return nil
	ptr := runtime.mem_alloc_bytes(node.settings_size, 16) or_else nil
	if ptr == nil do return nil
	p := raw_data(ptr)
	runtime.mem_copy(p, node.settings_default, node.settings_size)
	if _, is_null := v.(json.Null); v != nil && !is_null { // a JSON null is "no settings stored" too
		bytes, merr := json.marshal(v, {spec = .JSON}, context.temp_allocator)
		if merr == nil {
			pp := p
			if json.unmarshal_any(bytes, any{&pp, node.settings_ptr_tid}) != nil {
				log.warningf("[Render] pipeline node %q: its settings do not match %v, defaults used", node.name, node.settings_tid)
			}
		}
	}
	return p
}

// Every read has a writer that ran before it: the frame lane for a slot's
// node, earlier nodes in the same lane, an earlier final for "final".
@(private = "file")
_pipeline_check_reads :: proc(r: ^Pipeline_Runtime) {
	check_lane :: proc(lane: []Pipeline_Instance, frame: []Pipeline_Instance, slot: string) {
		written := make(map[string]bool, context.temp_allocator)
		has_final := false
		for inst in frame do for d in inst.writes do written[d.name] = true
		for inst in lane {
			for t in inst.reads {
				ok := t == SCENE_INPUT || (t == FINAL_INPUT ? has_final : (t in written || _writes_name(inst, t)))
				if !ok do log.warningf("[Render] pipeline node %q in %s reads %q, which nothing before it writes", inst.node.name, slot == "" ? "the frame lane" : fmt.tprintf("slot %q", slot), t)
			}
			for d in inst.writes {
				written[d.name] = true
				if d.final && !inst.node.frame do has_final = true
			}
		}
	}
	check_lane(r.frame[:], nil, "")
	for name, lane in r.slots do check_lane(lane[:], r.frame[:], name)
}

@(private = "file")
_writes_name :: proc(inst: Pipeline_Instance, name: string) -> bool {
	for d in inst.writes do if d.name == name do return true
	return false
}

// Runs the frame lane (each instance once per frame, whichever slot asks
// first) and then the slot's lane on `ctx`. A slot the pipeline does not
// declare falls back to Main with one warning. False when not even Main
// exists.
render_pipeline_run :: proc(slot: string, ctx: ^Render_Ctx) -> bool {
	r := render_pipeline_active()
	lane, ok := r.slots[slot]
	if !ok {
		if slot != MAIN_SLOT {
			_warn_missing_slot(slot)
			lane, ok = r.slots[MAIN_SLOT]
		}
		if !ok do return false
	}
	// The frame lane, captured for the Render Pipeline window whenever it
	// runs while the window is open (render_inspect.odin).
	inspect_frame := render_inspect_active()
	for inst in r.frame {
		// Stored +1 so frame 0 (tests, the first frame) runs too.
		if _frame_ran[inst.id] == gfx.frame_index + 1 do continue
		_frame_ran[inst.id] = gfx.frame_index + 1
		if inst.muted {
			if inspect_frame do _inspect_node_skipped(inst.id)
			continue
		}
		frame_ctx := Render_Ctx{view = ctx.view, pool = render_frame_pool(), node = inst.node, settings = inst.settings, reads = inst.reads, writes = inst.writes}
		if inspect_frame do _inspect_node_begins(inst.id)
		inst.node.run(&frame_ctx)
		if inspect_frame do _inspect_node_ends(inst.id, frame_ctx.pool)
	}
	inspect := _inspect_lane_begins(slot, ctx)
	for inst in lane {
		if inst.muted {
			if inspect do _inspect_node_skipped(inst.id)
			continue
		}
		ctx.node = inst.node
		ctx.settings = inst.settings
		ctx.reads = inst.reads
		ctx.writes = inst.writes
		if inspect do _inspect_node_begins(inst.id)
		inst.node.run(ctx)
		if inspect do _inspect_node_ends(inst.id, ctx.pool)
	}
	ctx.node = nil
	ctx.settings = nil
	ctx.reads = nil
	ctx.writes = nil
	_inspect_lane_ends(ctx)
	return true
}

// Whether the active pipeline declares the slot (the scene view asks for
// Editor and takes Main otherwise, without a warning).
render_pipeline_has_slot :: proc(slot: string) -> bool {
	return slot in render_pipeline_active().slots
}

@(private = "file")
_warn_missing_slot :: proc(slot: string) {
	if slot in _warned_slots do return
	context.allocator = runtime.default_allocator()
	_warned_slots[strings.clone(slot)] = true
	log.warningf("[Render] no slot %q in the render pipeline, rendering through %q", slot, MAIN_SLOT)
}
