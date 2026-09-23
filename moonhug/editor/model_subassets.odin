package editor

// A model's sub-assets for the project view: its mesh parts, then its clips
// (engine.Mesh_Part, engine.Mesh_Clip, both from the model's settings). A
// clip row drags as (model guid, clip id), which a clip field turns back into
// the clip's own guid (property_drawer_asset_guid.odin), so a clip is assigned
// straight from the model without extracting anything.

import "base:runtime"
import "moonhug:engine"
import "subassets"

_register_model_subassets :: proc() {
	for ext in ([]string{".glb", ".gltf"}) {
		subassets.register(ext, subassets.Provider{list = _model_sub_assets})
	}
}

@(private = "file")
_model_sub_assets :: proc(path: string, allocator: runtime.Allocator) -> []subassets.Sub_Asset {
	raw, ok := engine.asset_db_get_guid(path)
	if !ok do return nil
	guid := engine.Asset_GUID(raw)
	parts := engine.mesh_parts(guid)
	clips := engine.mesh_clips(guid)
	if len(parts) + len(clips) == 0 do return nil
	out := make([dynamic]subassets.Sub_Asset, 0, len(parts) + len(clips), allocator)
	for p in parts do append(&out, subassets.Sub_Asset{id = p.id, name = p.name})
	for c in clips do append(&out, subassets.Sub_Asset{id = c.id, name = c.name})
	return out[:]
}
