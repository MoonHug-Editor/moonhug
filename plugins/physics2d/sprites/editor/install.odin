package physics2d_sprites_editor

// Installs the sprite outline as what a new PolygonCollider2D takes its
// points from, in the editor: a game adds colliders from code with their
// points, and the shape is an editor-time step, as in other engines.

import physics2d "moonhug:packages/physics2d"
import physics2d_sprites "moonhug:packages/physics2d/sprites"

@(provider_install)
_install_sprite_outline :: proc() {
	physics2d.polygon_sprite_outline = physics2d_sprites.sprite_outline_of_owner
}
