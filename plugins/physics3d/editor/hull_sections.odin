package physics3d_editor

// The inspector rows of convex decompositions (hull_jobs.odin):
// - the model's Convex Decompositions section under its import settings,
//   where sets are added, edited and removed, then applied with the import
//   settings' Apply, and where a running or queued set is cancelled and a
//   failed or cancelled one is computed again;
// - a convex MeshCollider's Hulls dropdown, which picks the single convex
//   hull or one of its model's sets for the collider's mesh, with the set's
//   state beneath while it is not ready.
//
// A set is a sub-asset of its model (engine.Mesh_Hull_Set): the project
// window lists it under the model, and selecting it shows its own entry.

import "base:runtime"
import "core:fmt"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "moonhug:packages/engine"
import "moonhug:editor/inspector"
import "moonhug:editor/widgets"
import "moonhug:packages/engine/editor/mesh_editor"
import physics3d "moonhug:packages/physics3d"

@(provider_install)
_register_hull_sections :: proc() {
	inspector.add_asset_wrapper("mesh", _model_hull_section)
}

// --- The model's section ---------------------------------------------------------

@(private = "file")
_model_hull_section :: proc(ctx: ^inspector.Asset_Ctx) {
	inspector.draw(ctx)
	if ctx.settings.id != typeid_of(engine.MeshSettings) do return
	ms := cast(^engine.MeshSettings)ctx.settings.data
	// The model shows every set, a selected set only itself.
	only := engine.Local_ID(0)
	if ctx.sub != 0 {
		for s in ms.hull_sets do if s.id == ctx.sub do only = s.id
		if only == 0 do return // a part or a clip
	}

	im.Separator()
	im.SeparatorText("Convex Decompositions")
	widgets.tooltip("Hull sets a convex MeshCollider can pick, so a Rigidbody carries a concave mesh. Each set is computed in the background after Apply, and only sets whose mesh or values changed are computed again.")

	applied := hull_sets_applied(ctx.guid)
	remove := -1
	for &s, i in ms.hull_sets {
		if only != 0 && s.id != only do continue
		im.PushID(strings.clone_to_cstring(fmt.tprintf("%d", s.id), context.temp_allocator))
		defer im.PopID()

		if im.BeginCombo(inspector.field_row("Mesh"), strings.clone_to_cstring(_mesh_name(ctx.guid, s.part), context.temp_allocator)) {
			if im.Selectable("Whole model", s.part == 0) && s.part != 0 {
				s.part = 0
				inspector.mark_inspector_changed()
			}
			for p in engine.mesh_parts(ctx.guid) {
				if p.id == 0 do continue
				if im.Selectable(strings.clone_to_cstring(p.name, context.temp_allocator), s.part == p.id) && s.part != p.id {
					s.part = p.id
					inspector.mark_inspector_changed()
				}
			}
			im.EndCombo()
		}
		if im.DragInt(inspector.field_row("Max Hulls"), &s.max_hulls, 0.2, 2, 256) do inspector.mark_inspector_changed()
		widgets.tooltip("The most hulls the mesh is split into.")
		if im.DragFloat(inspector.field_row("Concavity"), &s.concavity, 0.002, 0.01, 1, "%.3f") do inspector.mark_inspector_changed()
		widgets.tooltip("How far, as a fraction of the mesh's size, a hull may stray from the surface before it is cut. Lower is closer and slower.")
		if im.DragInt(inspector.field_row("Remesh Resolution"), &s.remesh_resolution, 0.2, engine.MESH_HULL_REMESH_MIN, engine.MESH_HULL_REMESH_MAX) do inspector.mark_inspector_changed()
		widgets.tooltip("For a mesh that is not closed, which most game meshes are: it is first rebuilt as a closed surface on a grid of this many cells along its longest side. Finer keeps thin parts and costs time, coarser is faster and may close up thin parts. A closed mesh skips this.")

		// The state of what is applied for this set.
		applied_same := false
		for a in applied do if a == s { applied_same = true; break }
		im.AlignTextToFramePadding()
		if !applied_same {
			im.TextDisabled("Apply to compute")
		} else {
			state, detail := hull_set_state(ctx.guid, s.id)
			im.TextDisabled("%s", strings.clone_to_cstring(fmt.tprintf("%v: %s", state, detail), context.temp_allocator))
			#partial switch state {
			case .Queued, .Running:
				im.SameLine()
				if im.SmallButton("Cancel") do hull_set_cancel(ctx.guid, s.id)
			case .Failed, .Cancelled:
				im.SameLine()
				if im.SmallButton("Compute") do hull_set_compute(ctx.guid, s.id)
			}
		}
		im.SameLine()
		if im.SmallButton("Remove") do remove = i
		im.Spacing()
	}
	if remove >= 0 {
		ordered_remove(&ms.hull_sets, remove)
		inspector.mark_inspector_changed()
	}
	if only == 0 && im.Button("Add Convex Decomposition") {
		context.allocator = runtime.default_allocator()
		// Random, and unused by the applied sets and the unapplied ones.
		taken := make([dynamic]engine.Local_ID, context.temp_allocator)
		for s in ms.hull_sets do append(&taken, s.id)
		id := engine.mesh_new_sub_id(ctx.guid, taken[:])
		append(&ms.hull_sets, engine.Mesh_Hull_Set{id = id, part = 0, max_hulls = 8, concavity = 0.05, remesh_resolution = engine.MESH_HULL_REMESH_DEFAULT})
		inspector.mark_inspector_changed()
	}
}

@(private = "file")
_mesh_name :: proc(guid: engine.Asset_GUID, part: engine.Local_ID) -> string {
	if part == 0 do return "Whole model"
	for p in engine.mesh_parts(guid) do if p.id == part do return p.name
	return "(missing part)"
}

// --- The collider's row ----------------------------------------------------------

// The Hulls dropdown of a convex MeshCollider: the single convex hull, or a
// set its model lists for the collider's mesh. A set that is not ready says
// why beneath.
hull_set_row :: proc(c: ^physics3d.MeshCollider) {
	ref, has := physics3d.mesh_collider_ref(c)
	current := "Convex Hull"
	if c.hull_set != 0 {
		current = "(not in the model)"
		if has do if s, ok := engine.mesh_hull_set_of(engine.PPtr{guid = ref.guid, local_id = c.hull_set}); ok do current = mesh_editor.hull_set_name(ref.guid, s)
	}
	if im.BeginCombo(inspector.field_row("Hulls"), strings.clone_to_cstring(current, context.temp_allocator)) {
		if im.Selectable("Convex Hull", c.hull_set == 0) do _set_hull_set(c, 0)
		listed := 0
		if has do for s in engine.mesh_hull_sets(ref.guid) {
			if s.part != ref.local_id do continue
			listed += 1
			label := strings.clone_to_cstring(fmt.tprintf("%s##%d", mesh_editor.hull_set_name(ref.guid, s), s.id), context.temp_allocator)
			if im.Selectable(label, c.hull_set == s.id) do _set_hull_set(c, s.id)
		}
		if listed == 0 do im.TextDisabled("Add convex decompositions in the model's import settings")
		im.EndCombo()
	}
	widgets.tooltip("The single convex hull of the mesh, or one of the convex decompositions its model lists in its import settings: several hulls that follow a concave shape, for a Rigidbody.")
	if c.hull_set == 0 || !has do return
	state, detail := hull_set_state(ref.guid, c.hull_set)
	if state == .Ready do return
	inspector.field_row("")
	im.TextDisabled("%s", strings.clone_to_cstring(fmt.tprintf("%v: %s", state, detail), context.temp_allocator))
}

@(private = "file")
_set_hull_set :: proc(c: ^physics3d.MeshCollider, id: engine.Local_ID) {
	if c.hull_set == id do return
	c.hull_set = id
	inspector.mark_inspector_changed()
	inspector.record_nested_override(&c.hull_set, typeid_of(engine.Local_ID), "hull_set", true)
}
