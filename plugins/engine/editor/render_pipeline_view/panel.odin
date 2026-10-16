package render_pipeline_view

// The panel right of the matrix:
//
// - The selected step: what it does, its inputs and outputs as thumbnails
//   from the running frame (engine.render_inspect_*), "Show in scene view"
//   per output, its settings, mute, jump to code, remove, its port bindings
//   and what it drew.
// - The Resource List and the Step List: every row and column of the matrix
//   with its details, searchable, kept in step with the matrix's selection.

import "core:encoding/uuid"
import "core:fmt"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/widgets"
import gfx "moonhug:libs/gfx"
import "moonhug:packages/engine"

_THUMB_W     :: f32(148)
_THUMB_MAX_H :: f32(150)

// The selected step above, the lists below, each scrolling on its own and
// split by the shared splitter: a list scrolling to the selection never
// moves the step's details away. Each section shows while its toolbar
// button is lit.
_rp_panel :: proc(m: ^_Model) {
	prefs := &render_pipeline_prefs
	show_step := !prefs.hide_step
	show_lists := !prefs.hide_resources || !prefs.hide_steps
	if show_step && show_lists {
		total := im.GetContentRegionAvail().y - widgets.SPLITTER_SIZE
		ratio := prefs.step_ratio > 0 ? prefs.step_ratio : _RP_STEP_RATIO
		step_h := clamp(total * ratio, _RP_MIN_SECTION, max(total - _RP_MIN_SECTION, _RP_MIN_SECTION))
		lists_h := total - step_h
		if im.BeginChild("##rp_step", im.Vec2{0, step_h}) do _rp_step_details(m)
		im.EndChild()
		if widgets.splitter("##rp_pane_split", false, &step_h, &lists_h, _RP_MIN_SECTION, _RP_MIN_SECTION) do prefs.step_ratio = step_h / total
		if im.BeginChild("##rp_lists", im.Vec2{0, 0}) do _rp_lists(m)
		im.EndChild()
	} else if show_step {
		if im.BeginChild("##rp_step", im.Vec2{0, 0}) do _rp_step_details(m)
		im.EndChild()
	} else if show_lists {
		if im.BeginChild("##rp_lists", im.Vec2{0, 0}) do _rp_lists(m)
		im.EndChild()
	}
}

_rp_lists :: proc(m: ^_Model) {
	if !render_pipeline_prefs.hide_resources do _rp_resource_list(m)
	if !render_pipeline_prefs.hide_steps do _rp_step_list(m)
}

_RP_STEP_RATIO   :: f32(0.58)
_RP_MIN_SECTION  :: f32(80)

// --- The selected step ----------------------------------------------------------------

_rp_step_details :: proc(m: ^_Model) {
	ci := _rp_find_col(m, _rp.sel)
	if ci < 0 {
		im.TextDisabled("Select a step: click its column.")
		im.Spacing()
		return
	}
	c := m.cols[ci]
	e := c.entry
	n := c.step
	im.SeparatorText(fmt.ctprintf("%s", e.step))
	if n == nil {
		im.PushTextWrapPos(0)
		im.TextColoredUnformatted(_RP_DANGER, "Not installed: no linked plugin declares this step, so it does not run. Remove it or link the plugin.")
		im.PopTextWrapPos()
		if im.Button("Remove") do _rp_delete_step(e.id)
		return
	}
	if n.summary != "" {
		im.PushTextWrapPos(0)
		im.TextUnformatted(fmt.ctprintf("%s", n.summary))
		im.PopTextWrapPos()
	}
	im.TextDisabled("%s", fmt.ctprintf("%s, %s, %s", n.pkg, n.frame ? "per frame" : "per view", c.frame ? "frame lane" : fmt.tprintf("slot %s", _rp.slot)))

	muted := e.muted
	if im.Checkbox("Mute", &muted) do _rp_set_muted(e, muted)
	widgets.tooltip("Skip this step: the frame runs as if it were not there, so you see what it adds")
	im.SameLine()
	if im.Button("Open code") do _rp_open_code(n)
	widgets.tooltip(fmt.ctprintf("%s:%d", n.file, n.line))
	im.SameLine()
	if im.Button("Remove") {
		_rp_delete_step(e.id)
		return
	}

	_rp_images(m, ci)

	if n.settings_size > 0 {
		im.SeparatorText("Settings")
		_rp_settings_edit(e, n)
	}

	if im.CollapsingHeader("Ports") do _rp_ports(m, ci)
	if _rp_reads_scene(n) && im.CollapsingHeader("Drew") do _rp_drew(e.id)
	im.Spacing()
}

// The step's inputs (each as its writer left it) and outputs (as this step
// left them), from the last frame the window saw.
_rp_images :: proc(m: ^_Model, ci: int) {
	e := m.cols[ci].entry
	insp := engine.render_inspect_step(e.id)
	ran := insp != nil && insp.ran
	if e.muted {
		im.TextDisabled("Muted: it did not run.")
	} else if !ran {
		im.PushTextWrapPos(0)
		im.TextDisabled("Not seen running yet: open a view that renders slot %s.", fmt.ctprintf("%s", _rp.slot))
		im.PopTextWrapPos()
	}

	im.SeparatorText("Inputs")
	any_in := false
	for &r in m.res {
		a := r.cells[ci].access
		if a != .Read && a != .Read_Write do continue
		any_in = true
		if r.scene {
			objects := insp != nil ? len(insp.objects) : 0
			im.TextColoredUnformatted(_RP_IN, fmt.ctprintf("scene: %d object(s) drawn", objects))
			continue
		}
		w := _writer_before(&r, ci)
		from := w >= 0 ? m.cols[w].entry.step : "nothing"
		thumb: ^gfx.Render_Target
		if w >= 0 do thumb = engine.render_inspect_thumb(m.cols[w].entry.id, r.name)
		caption := r.cells[ci].via_final ? fmt.tprintf("as final, from %s", from) : fmt.tprintf("from %s", from)
		_rp_thumb(r.name, caption, thumb, _RP_IN, r.cells[ci].unwritten)
	}
	if !any_in do im.TextDisabled("none")

	im.SeparatorText("Outputs")
	any_out := false
	shown_id, shown_name, shown := engine.render_inspect_showing()
	for &r, ri in m.res {
		a := r.cells[ci].access
		if a != .Write && a != .Read_Write do continue
		any_out = true
		how := a == .Write ? "new contents" : "drawn over in place"
		thumb := ran ? engine.render_inspect_thumb(e.id, r.name) : nil
		_rp_thumb(r.name, how, thumb, a == .Write ? _RP_OUT : _RP_INOUT, false)
		im.PushIDInt(i32(ri))
		on := shown_id == e.id && shown_name == r.name
		if on do im.PushStyleColorImVec4(.Button, im.GetStyleColorVec4(.ButtonActive)^)
		if im.SmallButton(on ? "Showing in scene view" : "Show in scene view") {
			if on do engine.render_inspect_show(0, "")
			else do engine.render_inspect_show(e.id, r.name)
		}
		if on do im.PopStyleColor()
		im.PopID()
		if on && !shown do widgets.tooltip("The scene view shows its final image: this step did not write the target in the scene view's last frame")
		else do widgets.tooltip("The scene view shows this target as this step left it, instead of the finished image. Click again to stop.")
	}
	if !any_out do im.TextDisabled("none")
}

// One thumbnail with its name and a caption, or a placeholder.
_rp_thumb :: proc(name, caption: string, rt: ^gfx.Render_Target, color: im.Vec4, missing: bool) {
	im.TextColoredUnformatted(missing ? _RP_DANGER : color, fmt.ctprintf("%s", name))
	im.SameLine()
	im.TextDisabled("%s", fmt.ctprintf("%s", missing ? "no writer: the step gets nothing" : caption))
	if rt == nil {
		im.TextDisabled("  (no image)")
		return
	}
	// Fits a box as wide as the panel and _THUMB_MAX_H tall, keeping the
	// target's aspect (a portrait scene view stays a small portrait).
	aspect := f32(rt.width) / f32(max(rt.height, 1))
	w := min(_THUMB_W * 1.6, im.GetContentRegionAvail().x)
	h := w / aspect
	if h > _THUMB_MAX_H {
		h = _THUMB_MAX_H
		w = h * aspect
	}
	im.Image(im.TextureRef{_TexID = im.TextureID(uintptr(gfx.rt_imgui_id(rt)))}, im.Vec2{w, h})
}

// The read combos and write names: which targets this placed step uses
// instead of the names its code declares.
_rp_ports :: proc(m: ^_Model, ci: int) {
	e := m.cols[ci].entry
	n := m.cols[ci].step
	if len(n.reads) > 0 do im.TextDisabled("Reads")
	for port, i in n.reads {
		im.PushIDInt(i32(i))
		cur := engine.pipeline_entry_port(e^, port)
		if port == engine.SCENE_INPUT {
			im.TextUnformatted("scene (the view's objects)")
			im.PopID()
			continue
		}
		im.SetNextItemWidth(-110)
		if im.BeginCombo(fmt.ctprintf("%s", port), fmt.ctprintf("%s", cur)) {
			for t in _rp_available(m, ci, port, cur) {
				if im.Selectable(fmt.ctprintf("%s", t), t == cur) && t != cur {
					engine.pipeline_entry_bind(e, port, t)
					_rp_touch("Bind Port")
				}
			}
			im.Separator()
			im.SetNextItemWidth(160)
			if im.InputTextWithHint("##custom", "other target", cstring(&_rp.custom_buf[0]), len(_rp.custom_buf), {.EnterReturnsTrue}) {
				t := strings.trim_space(string(cstring(&_rp.custom_buf[0])))
				if t != "" {
					engine.pipeline_entry_bind(e, port, t)
					_rp_touch("Bind Port")
				}
				_rp.custom_buf = {}
				im.CloseCurrentPopup()
			}
			im.EndCombo()
		}
		widgets.tooltip(fmt.ctprintf("The code reads %q, this placed step reads the target chosen here", port))
		im.PopID()
	}

	if len(n.writes) > 0 do im.TextDisabled("Writes")
	for d, i in n.writes {
		im.PushIDInt(i32(100 + i))
		// The name edits a buffer and lands on leaving the field, so a rebind
		// is one step. Empty goes back to the declared name.
		local: [128]u8
		buf := &local
		if _rp.write_edit == i {
			buf = &_rp.write_buf
		} else {
			copy(local[:len(local) - 1], engine.pipeline_entry_port(e^, d.name))
		}
		im.SetNextItemWidth(-110)
		im.InputText(fmt.ctprintf("%s", d.name), cstring(&buf[0]), len(buf))
		if im.IsItemActivated() {
			_rp.write_edit = i
			_rp.write_buf = local
		}
		if im.IsItemDeactivated() && _rp.write_edit == i {
			_rp.write_edit = -1
			t := strings.trim_space(string(cstring(&_rp.write_buf[0])))
			if t != engine.pipeline_entry_port(e^, d.name) {
				engine.pipeline_entry_bind(e, d.name, t)
				_rp_touch("Bind Port")
			}
		}
		widgets.tooltip(fmt.ctprintf("%s%s. The code writes %q, this placed step writes the name given here", _rp_decl_info(d), d.final ? ", becomes the final image" : "", d.name))
		im.PopID()
	}
}

// The targets a read at column `ci` can take: every write of an earlier step
// (the frame lane's included for a slot), "final" in a slot, the declared
// name and the current one.
_rp_available :: proc(m: ^_Model, ci: int, port, cur: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	add :: proc(out: ^[dynamic]string, t: string) {
		for x in out do if x == t do return
		append(out, t)
	}
	for &r in m.res {
		if r.scene do continue
		for j in 0 ..< ci {
			a := r.cells[j].access
			if a == .Write || a == .Read_Write {
				add(&out, r.name)
				break
			}
		}
	}
	if !m.cols[ci].frame do add(&out, engine.FINAL_INPUT)
	add(&out, port)
	add(&out, cur)
	return out[:]
}

// The objects, meshes, materials and textures the step drew in the last frame
// the window saw. A click selects the object or pings the asset.
_rp_drew :: proc(id: i32) {
	insp := engine.render_inspect_step(id)
	if insp == nil || !insp.ran {
		im.TextDisabled("Nothing seen yet.")
		return
	}
	w := engine.ctx_world()
	if im.TreeNode(fmt.ctprintf("Objects (%d)", len(insp.objects))) {
		for h, i in insp.objects {
			name := "an object"
			if w != nil {
				if t := engine.pool_get(&w.transforms, engine.Handle(h)); t != nil do name = t.name
			}
			if im.Selectable(fmt.ctprintf("%s##obj%d", name, i)) do engine.inspector_request_select(h)
		}
		im.TreePop()
	}
	_rp_asset_tree("Meshes", insp.meshes[:])
	_rp_asset_tree("Materials", insp.materials[:])
	// The textures: the quads' own and the drawn materials'.
	textures := make([dynamic]engine.Asset_GUID, context.temp_allocator)
	add :: proc(list: ^[dynamic]engine.Asset_GUID, g: engine.Asset_GUID) {
		if g == {} do return
		for x in list do if x == g do return
		append(list, g)
	}
	for g in insp.textures do add(&textures, g)
	for mg in insp.materials {
		mat, ok := engine.material_load(mg)
		if !ok do continue
		add(&textures, mat.texture)
		for t in mat.textures do add(&textures, t.texture)
	}
	_rp_asset_tree("Textures", textures[:])
}

_rp_asset_tree :: proc(label: string, guids: []engine.Asset_GUID) {
	if !im.TreeNode(fmt.ctprintf("%s (%d)", label, len(guids))) do return
	defer im.TreePop()
	for g, i in guids {
		path, ok := engine.asset_db_get_path(uuid.Identifier(g))
		name := ok ? path : "(missing asset)"
		if slash := strings.last_index_byte(name, '/'); slash >= 0 do name = name[slash + 1:]
		if im.Selectable(fmt.ctprintf("%s##%s%d", name, label, i)) do engine.inspector_request_ping_asset(g)
		if ok do widgets.tooltip(fmt.ctprintf("%s", path))
	}
}

_rp_reads_scene :: proc(n: ^engine.Render_Step) -> bool {
	for r in n.reads do if r == engine.SCENE_INPUT do return true
	return false
}

// --- The lists ------------------------------------------------------------------------

_rp_resource_list :: proc(m: ^_Model) {
	if !im.CollapsingHeader("Resource List", {.DefaultOpen}) do return
	im.SetNextItemWidth(-1)
	im.InputTextWithHint("##res_search", "Search", cstring(&_rp.res_search[0]), len(_rp.res_search))
	filter := strings.to_lower(string(cstring(&_rp.res_search[0])), context.temp_allocator)
	for &r in m.res {
		if !_rp_row_visible(&r) do continue
		if filter != "" && !strings.contains(strings.to_lower(r.name, context.temp_allocator), filter) do continue
		selected := r.name == _rp.sel_res
		if selected && _rp.scroll_res do im.SetNextItemOpen(true)
		flags: im.TreeNodeFlags = {.OpenOnArrow, .SpanAvailWidth}
		if selected do flags += {.Selected}
		open := im.TreeNodeEx(fmt.ctprintf("%s##res_%s", r.name, r.name), flags)
		if im.IsItemClicked() && !im.IsItemToggledOpen() do _rp_set_string(&_rp.sel_res, r.name)
		if selected && _rp.scroll_res {
			im.SetScrollHereY(0.2)
			_rp.scroll_res = false
		}
		if !open do continue
		if r.scene {
			im.TextDisabled("the view's objects, collected before the frame runs")
		} else {
			if r.has_decl do im.TextUnformatted(fmt.ctprintf("%s", _rp_decl_info(r.decl)))
			writers := make([dynamic]string, context.temp_allocator)
			readers := make([dynamic]string, context.temp_allocator)
			for cell, ci in r.cells {
				if cell.access == .Write || cell.access == .Read_Write do append(&writers, m.cols[ci].entry.step)
				if cell.access == .Read || cell.access == .Read_Write do append(&readers, m.cols[ci].entry.step)
			}
			im.TextUnformatted(fmt.ctprintf("written by %s", len(writers) > 0 ? _rp_join(writers[:]) : "nothing"))
			im.TextUnformatted(fmt.ctprintf("read by %s", len(readers) > 0 ? _rp_join(readers[:]) : "nothing"))
			if r.first >= 0 do im.TextDisabled("%s", fmt.ctprintf("alive from %s to %s", m.cols[r.first].entry.step, m.cols[r.last].entry.step))
			if r.scratch do im.TextDisabled("scratch: only its writer uses it")
			if r.missing do im.TextColoredUnformatted(_RP_DANGER, "a step reads it before anything writes it")
			// Its state at the end of the frame: as its last writer left it.
			last_w := -1
			for cell, ci in r.cells do if cell.access == .Write || cell.access == .Read_Write do last_w = ci
			if last_w >= 0 {
				if thumb := engine.render_inspect_thumb(m.cols[last_w].entry.id, r.name); thumb != nil {
					_rp_thumb(r.name, fmt.tprintf("after %s", m.cols[last_w].entry.step), thumb, _rp_target_color(r.name), false)
				}
			}
		}
		im.TreePop()
	}
}

_rp_step_list :: proc(m: ^_Model) {
	if !im.CollapsingHeader("Step List", {.DefaultOpen}) do return
	im.SetNextItemWidth(-1)
	im.InputTextWithHint("##step_search", "Search", cstring(&_rp.step_search[0]), len(_rp.step_search))
	filter := strings.to_lower(string(cstring(&_rp.step_search[0])), context.temp_allocator)
	for c, ci in m.cols {
		e := c.entry
		if filter != "" && !strings.contains(strings.to_lower(e.step, context.temp_allocator), filter) do continue
		selected := e.id == _rp.sel
		if selected && _rp.scroll_step do im.SetNextItemOpen(true)
		flags: im.TreeNodeFlags = {.OpenOnArrow, .SpanAvailWidth}
		if selected do flags += {.Selected}
		label := fmt.ctprintf("%s%s%s##step_%d", c.frame ? "frame: " : "", e.step, e.muted ? " (muted)" : "", e.id)
		open := im.TreeNodeEx(label, flags)
		if im.IsItemClicked() && !im.IsItemToggledOpen() do _rp.sel = e.id
		if selected && _rp.scroll_step {
			im.SetScrollHereY(0.2)
			_rp.scroll_step = false
		}
		if !open do continue
		n := c.step
		if n == nil {
			im.TextColoredUnformatted(_RP_DANGER, "not installed")
			im.TreePop()
			continue
		}
		if n.summary != "" {
			im.PushTextWrapPos(0)
			im.TextUnformatted(fmt.ctprintf("%s", n.summary))
			im.PopTextWrapPos()
		}
		im.TextDisabled("%s", fmt.ctprintf("%s, %s", n.pkg, n.frame ? "per frame" : "per view"))
		for &r in m.res {
			switch r.cells[ci].access {
			case .Read:
				im.TextColoredUnformatted(_RP_IN, fmt.ctprintf("reads %s%s", r.name, r.cells[ci].via_final ? " (as final)" : ""))
			case .Write:
				im.TextColoredUnformatted(_RP_OUT, fmt.ctprintf("writes %s, new contents", r.name))
			case .Read_Write:
				im.TextColoredUnformatted(_RP_INOUT, fmt.ctprintf("reads and writes %s, keeps its contents", r.name))
			case .None:
			}
		}
		if hint := _rp_settings_hint(e, n); hint != "" do im.TextDisabled("%s", fmt.ctprintf("%s", hint))
		if im.SmallButton(fmt.ctprintf("Open code##code_%d", e.id)) do _rp_open_code(n)
		widgets.tooltip(fmt.ctprintf("%s:%d", n.file, n.line))
		im.TreePop()
	}
}
