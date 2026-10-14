package render_pipeline_view

// What the matrix shows, derived from the open document each frame: the
// passes of one slot as columns (the frame lane's first), and the resources
// they touch as rows, with one cell per pass and resource. Port bindings are
// resolved, and a read of `final` becomes a read of the target it is at that
// point of the lane (the last earlier write marked final).

import "core:slice"
import "moonhug:packages/engine"

_Access :: enum u8 {
	None,
	Read,
	Write,
	Read_Write, // in place: the pass keeps the contents and draws over them
}

_Column :: struct {
	entry: ^engine.Pipeline_Entry,
	node:  ^engine.Render_Node, // nil = not installed
	frame: bool,                // in the frame lane
	pos:   int,                 // position in its lane
}

_Cell :: struct {
	access:    _Access,
	via_final: bool, // the pass reads it as `final`
	unwritten: bool, // the pass reads it and nothing before it wrote it
}

_Resource :: struct {
	name:     string,
	scene:    bool,                      // the view's objects, from outside the frame
	decl:     engine.Render_Target_Decl, // as its first writer declares it
	has_decl: bool,
	cells:    []_Cell,                   // one per column
	first:    int,                       // lifetime, column indices
	last:     int,
	scratch:  bool,                      // written by one pass and read by none
	missing:  bool,                      // some read has no writer
}

_Model :: struct {
	cols:    []_Column,
	n_frame: int, // the first n_frame columns are the frame lane
	res:     []_Resource,
}

_rp_model :: proc(slot: string) -> _Model {
	doc := &_rp.doc
	cols := make([dynamic]_Column, context.temp_allocator)
	for e, i in engine.pipeline_lane(doc, "") do append(&cols, _Column{entry = e, node = engine.render_node_find(e.node), frame = true, pos = i})
	n_frame := len(cols)
	for e, i in engine.pipeline_lane(doc, slot) do append(&cols, _Column{entry = e, node = engine.render_node_find(e.node), pos = i})

	names := make([dynamic]string, context.temp_allocator)
	res := make([dynamic]_Resource, context.temp_allocator)
	row :: proc(names: ^[dynamic]string, res: ^[dynamic]_Resource, n_cols: int, name: string) -> ^_Resource {
		for x, i in names do if x == name do return &res[i]
		append(names, name)
		append(res, _Resource{name = name, cells = make([]_Cell, n_cols, context.temp_allocator), first = -1, last = -1, scene = name == engine.SCENE_INPUT})
		return &res[len(res) - 1]
	}

	for c, ci in cols {
		n := c.node
		if n == nil do continue
		for port in n.reads {
			t := engine.pipeline_entry_port(c.entry^, port)
			via_final := false
			if t == engine.FINAL_INPUT {
				if f, ok := _final_before(cols[:], n_frame, ci); ok {
					t = f
					via_final = true
				}
			}
			r := row(&names, &res, len(cols), t)
			cell := &r.cells[ci]
			cell.access = cell.access == .Write ? .Read_Write : (cell.access == .None ? .Read : cell.access)
			cell.via_final = via_final
		}
		for d in n.writes {
			t := engine.pipeline_entry_port(c.entry^, d.name)
			r := row(&names, &res, len(cols), t)
			if !r.has_decl {
				r.decl = d
				r.decl.name = t
				r.has_decl = true
			}
			cell := &r.cells[ci]
			cell.access = cell.access == .Read ? .Read_Write : (cell.access == .None ? .Write : cell.access)
		}
	}

	// Lifetimes, scratch rows, reads without a writer.
	for &r in res {
		writers, readers := 0, 0
		for cell, ci in r.cells {
			if cell.access == .None do continue
			if r.first < 0 do r.first = ci
			r.last = ci
			if cell.access == .Write || cell.access == .Read_Write do writers += 1
			if cell.access == .Read || cell.access == .Read_Write do readers += 1
		}
		r.scratch = !r.scene && writers == 1 && readers == 0 && r.first == r.last
		if r.scene do continue
		for &cell, ci in r.cells {
			if cell.access != .Read && cell.access != .Read_Write do continue
			if _writer_before(&r, ci) < 0 {
				cell.unwritten = true
				r.missing = true
			}
		}
	}

	// The scene row first, then the rest in first-touch order (as built).
	slice.stable_sort_by(res[:], proc(a, b: _Resource) -> bool { return a.scene && !b.scene })
	return _Model{cols = cols[:], n_frame = n_frame, res = res[:]}
}

// The target `final` is at column `ci`: the last earlier write of the lane
// marked final. The frame lane has none.
_final_before :: proc(cols: []_Column, n_frame, ci: int) -> (string, bool) {
	if ci < n_frame do return "", false
	for j := ci - 1; j >= n_frame; j -= 1 {
		n := cols[j].node
		if n == nil do continue
		for d in n.writes do if d.final do return engine.pipeline_entry_port(cols[j].entry^, d.name), true
	}
	return "", false
}

// The column that last wrote the resource before column `ci`: earlier
// columns of the lane, then the frame lane for a slot column. -1 = none.
// The frame columns come first, so scanning back from a slot column reaches
// the frame lane last, and from a frame column only earlier frame columns.
_writer_before :: proc(r: ^_Resource, ci: int) -> int {
	for j := ci - 1; j >= 0; j -= 1 {
		a := r.cells[j].access
		if a == .Write || a == .Read_Write do return j
	}
	return -1
}

// The columns after `ci` that read what column `ci` wrote, until the next
// column that writes the resource.
_readers_after :: proc(r: ^_Resource, ci: int) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	for j in ci + 1 ..< len(r.cells) {
		a := r.cells[j].access
		if a == .Read || a == .Read_Write do append(&out, j)
		if a == .Write || a == .Read_Write do break
	}
	return out[:]
}

_rp_find_res :: proc(m: ^_Model, name: string) -> ^_Resource {
	for &r in m.res do if r.name == name do return &r
	return nil
}

_rp_find_col :: proc(m: ^_Model, id: i32) -> int {
	for c, i in m.cols do if c.entry.id == id do return i
	return -1
}

// Whether the matrix shows the row and the column under the filters.
_rp_row_visible :: proc(r: ^_Resource) -> bool {
	if r.scene && render_pipeline_prefs.hide_scene do return false
	if r.scratch && render_pipeline_prefs.hide_scratch do return false
	return true
}

_rp_col_visible :: proc(c: _Column) -> bool {
	return !(c.entry.muted && render_pipeline_prefs.hide_muted)
}
