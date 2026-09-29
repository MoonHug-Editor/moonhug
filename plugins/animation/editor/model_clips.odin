package animation_editor

// Clips inside a model (docs/AnimationComponent.md): what this package adds
// to the editor's model rows.
//
// - The selected clip's section in the Project Inspector: its settings, or a
//   remap for a clip the model no longer has.
// - The sampler that poses the editor's clip rig, for the clip preview and
//   clip thumbnails (subassets.clip_sampler).
// - The live preview of an edited .anim document, so an undone or redone
//   clip reaches the clip cache (inspector.doc_preview_register).
//
// The clip rows themselves come from the model provider in
// engine_editor/mesh_editor, which lists parts and clips. A clip row drags as
// (model guid, clip id), which a clip field turns back into the clip's own
// guid (property_drawer_asset_guid.odin), so a clip is assigned straight from
// the model without extracting anything.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "moonhug:engine"
import "moonhug:editor/inspector"
import "moonhug:editor/subassets"
import "moonhug:editor/widgets"
import anim "moonhug:packages/animation"

@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
model_clips_install :: proc() {
	inspector.add_asset_wrapper("mesh", _model_clip_section)
	subassets.clip_sampler = _sample_clip
	inspector.doc_preview_register(typeid_of(anim.AnimationClip), proc(guid: engine.Asset_GUID, doc: any) {
		anim.animation_clip_preview(guid, doc.(anim.AnimationClip))
	})
}

@(private = "file")
_sample_clip :: proc(root: engine.Transform_Handle, clip: engine.Asset_GUID, t: f32) -> (length: f32, ok: bool) {
	c, lok := anim.animation_clip_load(clip)
	if !lok do return 0, false
	anim.animation_clip_apply(c, root, t)
	return c.length, true
}

// --- The selected clip's section in the Project Inspector -----------------------
//
// Selecting a clip under a model selects the model with that sub id, so the
// model's import settings show. This wrapper adds, below them, the one clip's
// own settings — or, for a clip the model no longer has, a remap. Edits land in
// the model's import settings document (engine.Mesh_Clip.settings inside it,
// inspector/import_settings_docs.odin), which records them for undo, and the
// Apply button above saves the meta and reimports, which is when the bake
// picks them up. Settings live in the meta, never in the artifact, the same rule a
// standalone .anim follows.

// Typed copy of the selected clip's settings: the reflected drawer edits a
// struct, the document holds a JSON value. Re-read from the document every
// frame no widget is held, so an undo that swapped the document shows at once
// and the next edit starts from it.
@(private = "file") _clip_edit: struct {
	path:  string, // owned
	id:    engine.Local_ID,
	s:     anim.Animation_Clip_Settings,
	valid: bool,
}

@(private = "file")
_clip_edit_load :: proc(path: string, clip: ^engine.Mesh_Clip) {
	context.allocator = runtime.default_allocator()
	delete(_clip_edit.path)
	_clip_edit.path = strings.clone(path)
	_clip_edit.id = clip.id
	_clip_edit.s = {}
	if clip.settings != nil {
		engine._settings_overlay(any{&_clip_edit.s, typeid_of(anim.Animation_Clip_Settings)}, clip.settings)
	}
	anim.on_validate_Animation_Clip_Settings(&_clip_edit.s)
	_clip_edit.valid = true
}

// Writes the typed copy back into the meta entry as a JSON value, on the
// default allocator the working-copy settings live on.
@(private = "file")
_clip_edit_store :: proc(clip: ^engine.Mesh_Clip) {
	context.allocator = runtime.default_allocator()
	bytes, merr := json.marshal(_clip_edit.s, {spec = .JSON}, context.temp_allocator)
	if merr != nil do return
	v, perr := json.parse(bytes, .JSON, true)
	if perr != nil do return
	if clip.settings != nil do json.destroy_value(clip.settings)
	clip.settings = v
}

@(private = "file")
_model_clip_section :: proc(ctx: ^inspector.Asset_Ctx) {
	inspector.draw(ctx) // Apply + the reflected MeshSettings

	if ctx.settings.id != typeid_of(engine.MeshSettings) do return
	if ctx.sub == 0 do return
	ms := cast(^engine.MeshSettings)ctx.settings.data
	idx := -1
	for c, i in ms.clips do if c.id == ctx.sub { idx = i; break }
	if idx < 0 do return // a mesh part
	clip := &ms.clips[idx]

	im.Separator()
	im.SeparatorText(strings.clone_to_cstring(fmt.tprintf("Clip: %s", clip.name), context.temp_allocator))

	if clip.orphan {
		im.TextDisabled("Not in the model any more. Remap it and every reference follows.")
		if im.BeginCombo("Remap to", "choose a clip") {
			for &c in ms.clips {
				if c.orphan do continue
				if im.Selectable(strings.clone_to_cstring(c.name, context.temp_allocator)) {
					// The orphan's guid is the one scenes hold, so it moves to
					// the chosen clip. That clip's own guid, minted at import
					// and referenced by nothing yet, goes.
					c.guid = clip.guid
					if c.settings == nil {
						c.settings = clip.settings
						clip.settings = nil
					}
					context.allocator = runtime.default_allocator()
					if clip.settings != nil do json.destroy_value(clip.settings)
					ordered_remove(&ms.clips, idx)
					inspector.mark_inspector_changed()
					_clip_edit.valid = false
					im.EndCombo()
					return
				}
			}
			im.EndCombo()
		}
		widgets.tooltip("Apply above to bake. The chosen clip takes this entry's guid.")
		return
	}

	if !_clip_edit.valid || _clip_edit.path != ctx.path || _clip_edit.id != clip.id || !im.IsAnyItemActive() {
		_clip_edit_load(ctx.path, clip)
	}
	// The drawer sets the shared changed flag. Read it around this draw only,
	// and put the caller's own state back afterwards.
	outer := inspector.consume_inspector_changed()
	inspector.draw_inspector(any{&_clip_edit.s, typeid_of(anim.Animation_Clip_Settings)})
	if inspector.consume_inspector_changed() {
		_clip_edit_store(clip)
		outer = true
	}
	if outer do inspector.mark_inspector_changed()
	im.TextDisabled("Apply above to bake the clip with these settings.")
}
