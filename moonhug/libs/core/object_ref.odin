package core

import "core:encoding/uuid"

Local_ID :: distinct i64
Asset_GUID :: distinct uuid.Identifier

asset_guid_is_empty :: proc(g: Asset_GUID) -> bool {
	return g == Asset_GUID{}
}

// Persistent pointer — survives serialization/reload
// guid == 0 is in same file (local). guid != 0 is cross-asset
PPtr :: struct {
    local_id : Local_ID,
    guid : Asset_GUID,
}

// reference to local object
Ref_Local :: struct {
    local_id : Local_ID,
    handle : Handle `json:"-"`,
}

// reference to local or cross-asset object
Ref :: struct {
    pptr: PPtr,
    handle : Handle `json:"-"`,
}

Owned :: distinct Ref_Local

// An object a reference picker lists: the handle to pick, its name, and its
// path from the root down ("Root/Foo/Bar", the owner's path for a component).
// The provider that found it owns the allocation.
Found_Object :: struct {
	handle: Handle,
	name:   string,
	path:   string,
}

// A loaded scene as undo remembers it: its session id, which an in-place
// reload (Stop after Play, revert) keeps.
// - Not a pointer: a reload frees the Scene struct, and a stale pointer can
//   match another scene allocated at the same address.
// - Not the asset guid: the same file can be loaded twice (Open Scene
//   Additive), and an unsaved scene has none.
// Every path that replaces a scene with a NEW one (open, nested edit, unload)
// purges its undo entries first, so nothing needs to find a scene across that.
Scene_Ref :: struct {
	id: u32, // Scene.session_id, 0 = no scene
}
