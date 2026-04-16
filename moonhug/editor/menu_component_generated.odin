package editor

import engine "../engine"
import "menu"

register_component_menus :: proc() {
	menu.add_menu_item("Component/Camera", "", proc() { _component_menu_add(.Camera) }, 0)
	menu.add_menu_item("Component/Lifetime", "", proc() { _component_menu_add(.Lifetime) }, 0)
	menu.add_menu_item("Component/NestedScene", "", proc() { _component_menu_add(.NestedScene) }, 0)
	menu.add_menu_item("Component/Player", "", proc() { _component_menu_add(.Player) }, 0)
	menu.add_menu_item("Component/Script", "", proc() { _component_menu_add(.Script) }, 0)
	menu.add_menu_item("Component/SpriteRenderer", "", proc() { _component_menu_add(.SpriteRenderer) }, 0)
}

_component_menu_add :: proc(key: engine.TypeKey) {
	tH := hierarchy_get_selected()
	if tH == _HANDLE_NONE do return
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return
	_, existing_idx := engine.transform_find_comp(t, key)
	if existing_idx >= 0 do return
	engine.transform_add_comp(tH, key)
}
