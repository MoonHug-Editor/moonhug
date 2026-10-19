package drawers

// The Groups component's inspector (plugins/engine/docs/Groups.md): the
// picker, then a Members button that opens a popup with every group the
// object is in, its alive and active counts, and its alive members. Clicking
// a member selects it. Alt held while the popup opens lists every named
// group instead. The lists exist only in the running game, so the button is
// disabled in edit mode.

import "core:fmt"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/inspector"
import "moonhug:editor/session"
import "moonhug:editor/widgets"
import engine "moonhug:packages/engine"

@(provider_install)
_register_groups_inspector :: proc() {
	inspector.add_component_wrapper(typeid_of(engine.Groups), _groups_inspector)
}

@(private = "file")
_groups_inspector :: proc(ctx: ^inspector.Component_Ctx) {
	inspector.draw(ctx)
	c := cast(^engine.Groups)ctx.ptr
	playing := engine.game_running()
	btn_w: f32 = 120
	im.SetCursorPosX(im.GetCursorPosX() + max((im.GetContentRegionAvail().x - btn_w) * 0.5, 0))
	im.BeginDisabled(!playing)
	if im.Button("Members", {btn_w, 0}) {
		// Alt at the click: every named group, not only this object's.
		_members_all = im.IsKeyDown(.LeftAlt) || im.IsKeyDown(.RightAlt)
		im.OpenPopup("##groups_members")
	}
	im.EndDisabled()
	widgets.tooltip(playing ? "The objects alive and active in this object's groups\nAlt+Click: every group" : "The group lists exist only while the game runs", im.HoveredFlags_AllowWhenDisabled)
	if !im.BeginPopup("##groups_members") do return
	defer im.EndPopup()

	w := engine.ctx_world()
	names := engine.layer_names(engine.GROUP_DOMAIN)
	any_group := false
	for g in 0 ..< engine.LAYER_COUNT {
		if _members_all {
			if names == nil || names[g] == "" do continue
		} else if c.groups & (u32(1) << u32(g)) == 0 {
			continue
		}
		any_group = true
		name := names != nil && names[g] != "" ? names[g] : fmt.tprintf("Group %d", g)
		alive := engine.group_alive(g)
		active := engine.group_active(g)
		// A group with no member opens nothing.
		if !im.BeginMenu(fmt.ctprintf("%s  (%d alive, %d active)##group%d", name, len(alive), len(active), g), len(alive) > 0) do continue
		for h in alive {
			t := engine.pool_get(&w.transforms, engine.Handle(h))
			if t == nil do continue
			is_active := false
			for a in active do if a == h { is_active = true; break }
			label := fmt.ctprintf("%s%s##%d_%d", t.name, is_active ? "" : "  (inactive)", h.index, h.generation)
			if im.MenuItem(label, nil, h == c.owner) do session.select_only(h)
			widgets.tooltip(is_active ? "Alive and active: select it" : "Alive, not active: select it")
		}
		im.EndMenu()
	}
	if !any_group do im.TextDisabled(_members_all ? "No named groups" : "In no group")
}

// Whether the open Members popup lists every named group (Alt at the click).
@(private = "file") _members_all: bool
