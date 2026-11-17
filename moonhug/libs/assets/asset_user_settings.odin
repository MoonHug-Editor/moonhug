package assets

// An asset that leaves the project takes its per-asset user settings with it
// (core.Per_Asset): the Hierarchy's open rows of a deleted scene, where the
// Scene window looked at it. A rename keeps them: the guid stays.

import "core:encoding/uuid"
import core "moonhug:libs/core"

@(asset_on_changed)
asset_on_changed_user_settings :: proc(guid: core.Asset_GUID, path: string, change: Asset_Change) {
	if change == .Removed do core.per_asset_drop_all(guid)
}

// Whether the project still has the asset `guid`: what per_asset_prune keeps.
asset_db_knows :: proc(guid: core.Asset_GUID) -> bool {
	_, ok := asset_db_get_path(uuid.Identifier(guid))
	return ok
}
