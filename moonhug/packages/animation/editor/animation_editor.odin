package animation_editor

// Editor-only half of the animation package. The PlayableDirector wrapper
// adds the Timeline picker row (PPtr has no generic drawer — the picker
// edits the guid, ext-filtered to .timeline) above the default rows.
// Never compiled into the app.

import im "moonhug:external/odin-imgui"
import "moonhug:engine"
import "moonhug:editor/inspector"
import "moonhug:editor/undo"
import anim "moonhug:packages/animation"

@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
animation_inspector_install :: proc() {
	inspector.add_component_wrapper(typeid_of(anim.PlayableDirector), _director_inspector)
}

// Whole-component diff session for the picker (it commits from a popup with
// no gesture): records only when the value actually changed.
@(private = "file")
_session_begin :: proc() -> undo.Edit_Session {
	if o, ok := undo.current_owner(); ok && o.kind == .Pooled {
		targets := [1]undo.Edit_Target{undo.edit_target_whole(o.handle)}
		return undo.edit_session_begin(targets[:], "Timeline")
	}
	return {}
}

_director_inspector :: proc(ctx: ^inspector.Component_Ctx) {
	d := cast(^anim.PlayableDirector)ctx.ptr

	im.PushIDStr("timeline", nil)
	sess := _session_begin()
	before := d.timeline.guid
	inspector.current_field_ext_filter = "timeline"
	if drawer := inspector.resolve_property_drawer(typeid_of(engine.Asset_GUID)); drawer != nil {
		drawer(&d.timeline.guid, typeid_of(engine.Asset_GUID), "Timeline")
	}
	inspector.current_field_ext_filter = ""
	changed := d.timeline.guid != before
	undo.edit_session_end(&sess)
	if changed {
		d.timeline.local_id = 0 // whole asset until embedded timelines exist
		inspector.mark_inspector_changed()
		inspector.record_nested_override(&d.timeline, typeid_of(engine.PPtr), "timeline", true)
	}
	im.PopID()

	inspector.draw(ctx) // wrap, speed, manual start, bindings
}
