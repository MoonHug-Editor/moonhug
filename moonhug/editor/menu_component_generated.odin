package editor

import engine "../engine"
import "menu"
import "undo"

register_component_menus :: proc() {
	menu.add_menu_item("Component/Camera", "", proc() { _component_menu_add(.Camera) })
	menu.add_menu_item("Component/DemoMenu", "", proc() { _component_menu_add(.DemoMenu) })
	menu.add_menu_item("Component/Lifetime", "", proc() { _component_menu_add(.Lifetime) })
	menu.add_menu_item("Component/Light", "", proc() { _component_menu_add(.Light) })
	menu.add_menu_item("Component/MeshFilter", "", proc() { _component_menu_add(.MeshFilter) })
	menu.add_menu_item("Component/MeshRenderer", "", proc() { _component_menu_add(.MeshRenderer) })
	menu.add_menu_item("Component/Physics/BoxCollider", "", proc() { _component_menu_add(.BoxCollider) })
	menu.add_menu_item("Component/Physics/CapsuleCollider", "", proc() { _component_menu_add(.CapsuleCollider) })
	menu.add_menu_item("Component/Physics/Rigidbody", "", proc() { _component_menu_add(.Rigidbody) })
	menu.add_menu_item("Component/Physics/SphereCollider", "", proc() { _component_menu_add(.SphereCollider) })
	menu.add_menu_item("Component/Physics2D/BoxCollider2D", "", proc() { _component_menu_add(.BoxCollider2D) })
	menu.add_menu_item("Component/Physics2D/CapsuleCollider2D", "", proc() { _component_menu_add(.CapsuleCollider2D) })
	menu.add_menu_item("Component/Physics2D/CircleCollider2D", "", proc() { _component_menu_add(.CircleCollider2D) })
	menu.add_menu_item("Component/Physics2D/Rigidbody2D", "", proc() { _component_menu_add(.Rigidbody2D) })
	menu.add_menu_item("Component/Player", "", proc() { _component_menu_add(.Player) })
	menu.add_menu_item("Component/Plugin Example/Spinner", "", proc() { _component_menu_add(.Spinner) })
	menu.add_menu_item("Component/Projectile", "", proc() { _component_menu_add(.Projectile) })
	menu.add_menu_item("Component/SceneRefs", "", proc() { _component_menu_add(.SceneRefs) })
	menu.add_menu_item("Component/Script", "", proc() { _component_menu_add(.Script) })
	menu.add_menu_item("Component/SpriteRenderer", "", proc() { _component_menu_add(.SpriteRenderer) })
	menu.add_menu_item("Component/SpriteSortingGroup", "", proc() { _component_menu_add(.SpriteSortingGroup) })
	menu.add_menu_item("Component/Tank", "", proc() { _component_menu_add(.Tank) })
}

_component_menu_add :: proc(key: engine.TypeKey) {
	tH := hierarchy_get_selected()
	if tH == _HANDLE_NONE do return
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return
	_, existing_idx := engine.transform_find_comp(t, key)
	if existing_idx >= 0 do return
	owned, _ := engine.transform_add_comp(tH, key)
	undo.record_add_component(tH, owned.handle, len(t.components) - 1)
}
