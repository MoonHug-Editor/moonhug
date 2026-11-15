package tween_editor

// The Tweens window: every live run, what it animates and how far it is, with
// buttons to pause, complete and stop one. It answers "what is still running"
// while a game plays.

import "core:fmt"
import "core:strings"
import im "moonhug:external/odin-imgui"
import engine "moonhug:packages/engine"
import tween "moonhug:packages/tween"
import wnd "moonhug:editor/window"

@(private = "file")
_cstr :: proc(format: string, args: ..any) -> cstring {
	return strings.clone_to_cstring(fmt.tprintf(format, ..args), context.temp_allocator)
}

@(private = "file")
_object_name :: proc(tH: engine.Transform_Handle) -> string {
	if tH == {} do return "-"
	t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH))
	return t.name if t != nil else "(gone)"
}

@(editor_window={id="tweens", title="Tweens", icon="SHOW_CHART", width=860, height=320})
tweens_window_draw :: proc(w: ^wnd.Window) {
	if engine.ctx_world() == nil {
		im.TextDisabled("No world.")
		return
	}
	runs := tween.run_infos()
	im.TextUnformatted(_cstr("%d running", len(runs)))
	im.SameLine()
	if im.SmallButton("Stop All") do tween.stop_all()
	im.Separator()
	if len(runs) == 0 {
		im.TextDisabled("No tween is running.")
		return
	}

	if im.BeginTable("##tweens", 7, im.TableFlags_BordersInnerH | im.TableFlags_RowBg | im.TableFlags_SizingStretchProp | im.TableFlags_ScrollY) {
		im.TableSetupColumn("#", {.WidthFixed}, 28)
		im.TableSetupColumn("Tween", {}, 4)
		im.TableSetupColumn("Object", {}, 5)
		im.TableSetupColumn("Clock", {}, 2)
		im.TableSetupColumn("Time", {}, 3)
		im.TableSetupColumn("State", {}, 2)
		im.TableSetupColumn("##actions", {.WidthFixed}, 190)
		im.TableHeadersRow()

		for r in runs {
			im.PushIDInt(i32(r.handle.index))
			defer im.PopID()
			im.TableNextRow()

			im.TableSetColumnIndex(0)
			im.TextUnformatted(_cstr("%d", r.handle.index))

			im.TableSetColumnIndex(1)
			im.TextUnformatted(_cstr("%v", r.root))

			im.TableSetColumnIndex(2)
			if r.bound && r.owner != r.subject {
				im.TextUnformatted(_cstr("%s (bound to %s)", _object_name(r.subject), _object_name(r.owner)))
			} else {
				im.TextUnformatted(_cstr("%s%s", _object_name(r.subject), " (bound)" if r.bound else ""))
			}

			im.TableSetColumnIndex(3)
			im.TextUnformatted(_cstr("%v%s", r.clock, "" if r.time_scale == 1 else fmt.tprintf(" x%.2f", r.time_scale)))

			im.TableSetColumnIndex(4)
			if r.length_known && r.length > 0 {
				im.ProgressBar(clamp(r.elapsed / r.length, 0, 1), im.Vec2{-1, 0}, _cstr("%.2f / %.2f s", r.elapsed, r.length))
			} else {
				im.TextUnformatted(_cstr("%.2f s", r.elapsed))
			}

			im.TableSetColumnIndex(5)
			state := "running"
			switch {
			case r.done:    state = "done, kept"
			case r.paused:  state = "paused"
			case r.waiting: state = "waiting"
			}
			im.TextUnformatted(strings.clone_to_cstring(state, context.temp_allocator))

			im.TableSetColumnIndex(6)
			if im.SmallButton("Resume" if r.paused else "Pause") do tween.set_paused(r.handle, !r.paused)
			im.SameLine()
			if im.SmallButton("Complete") do tween.complete(r.handle)
			im.SameLine()
			if im.SmallButton("Stop") do tween.stop(r.handle)
		}
		im.EndTable()
	}
}

@(menu_item={path="Window/Animation/Tweens", shortcut="", help="Opens the list of running tweens"})
tweens_window_open :: proc() {
	wnd.open("tweens")
}
