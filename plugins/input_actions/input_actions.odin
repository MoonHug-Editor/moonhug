package input_actions

// Input actions (docs/InputActions.md): game code reads named actions
// ("Jump", "Move") instead of keys, and an Input Actions asset says which
// controls drive them. The asset holds action maps, each a set of actions
// with bindings. Maps are pushed on a stack with a priority: the Player map
// stays, Vehicle pushes over it, Menu over everything. For each control the
// highest map that binds it answers, and a map consumes the controls below
// it: all of them, or only those of its actions marked `consumed`.
//
// Values resolve once per frame (frame_tick's update, before every game
// update) and once per fixed tick, from moonhug:libs/input's frame and fixed
// views. An action's pressed and released are edges of its own down state,
// so a tap between two ticks still reads as one press on the next tick.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:reflect"
import "core:strings"
import "moonhug:libs/input"
import "moonhug:libs/log"
import "moonhug:packages/engine"

// The asset: action maps with their actions and bindings.
@(typ_guid={guid = "c2f1a9e4-5b7d-4e83-9a06-1f4d8c2b7e65", menu_assets_create = {menu_name = "Input Actions", file_name = "InputActions.asset"}})
Input_Actions :: struct {
	contexts: [dynamic]Mapping_Context,
}

Mapping_Context :: struct {
	name: string,
	// Among the pushed maps, higher answers first.
	priority: int,
	// What this map takes from the maps below it while pushed: every control,
	// or only the controls of its actions marked `consumed`.
	consume: Consume_Input,
	actions: [dynamic]Action,
}

Consume_Input :: enum u8 {
	All,
	Listed,
}

Action :: struct {
	name: string,
	value_type: Value_Type,
	// With the map's consume = Listed: the maps below do not see this
	// action's controls.
	consume_input: bool,
	// Below it a value reads as zero: a stick's rest noise. Radial for Axis2D.
	dead_zone: f32,
	mappings: [dynamic]Key_Mapping,
}

Value_Type :: enum u8 {
	Digital, // down, pressed, released
	Axis1D, // one value, -1..1 from buttons, any range from an axis
	Axis2D, // two values: a stick, WASD, the mouse delta
}

// One control driving an action. `control` names it (key_parse):
// "key:W", "key:SPACE", "mouse:Left", "mouse:Delta", "mouse:Wheel",
// "pad:SOUTH", "pad:LEFT_STICK", "pad:RIGHT_STICK", "pad:LEFTX",
// "pad:LEFT_TRIGGER". `part` is what the control feeds: the whole value, or
// one side of an axis (Positive and Negative for Axis, the four directions
// for Axis2D) so buttons compose into axes. `scale` multiplies the value,
// 0 reads as 1.
Key_Mapping :: struct {
	key: Key_Name,
	modifier:    Modifier,
	scalar:   f32,
}

// A control name, "device:name" (key_parse). Its own type so the editor
// draws it as a picker with a search and a Listen button (editor/control_drawer.odin).
Key_Name :: distinct string

Modifier :: enum u8 {
	Whole,
	Positive,
	Negative,
	Up,
	Down,
	Left,
	Right,
}

reset_Input_Actions :: proc(a: ^Input_Actions) {
	cleanup_Input_Actions(a)
}

cleanup_Input_Actions :: proc(a: ^Input_Actions) {
	for &m in a.contexts {
		delete(m.name)
		for &ac in m.actions {
			delete(ac.name)
			for &b in ac.mappings do delete(string(b.key))
			delete(ac.mappings)
		}
		delete(m.actions)
	}
	delete(a.contexts)
	a^ = {}
}

// The Input project setting: which Input Actions asset the game uses.
Input_Settings :: struct {
	actions: engine.Asset_GUID `ref:"Input_Actions" expand`,
}

@(project_settings={name="Input"})
input_settings: Input_Settings

// --- Controls -------------------------------------------------------------------

// Every control name a binding can use, by device, for the editor's picker.
key_names :: proc(allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for n in reflect.enum_field_names(input.Key) {
		if n == "UNKNOWN" || n == "COUNT" do continue
		append(&out, fmt.aprintf("key:%s", n, allocator = allocator))
	}
	for n in reflect.enum_field_names(input.Mouse_Button) do append(&out, fmt.aprintf("mouse:%s", n, allocator = allocator))
	append(&out, "mouse:Delta", "mouse:Wheel")
	append(&out, "pad:LEFT_STICK", "pad:RIGHT_STICK")
	for n in reflect.enum_field_names(input.Gamepad_Axis) {
		if n == "INVALID" do continue
		append(&out, fmt.aprintf("pad:%s", n, allocator = allocator))
	}
	for n in reflect.enum_field_names(input.Gamepad_Button) {
		if n == "INVALID" do continue
		append(&out, fmt.aprintf("pad:%s", n, allocator = allocator))
	}
	return out[:]
}

// The control pressed this frame, for the picker's Listen: a key, a mouse
// button or a gamepad button, "" when none.
key_pressed_now :: proc(allocator := context.temp_allocator) -> string {
	for i in 0 ..< input.MAX_KEYS {
		if input.key_pressed(input.Key(i)) do return fmt.aprintf("key:%s", reflect.enum_string(input.Key(i)), allocator = allocator)
	}
	for b in input.Mouse_Button {
		if input.mouse_pressed(b) do return fmt.aprintf("mouse:%s", reflect.enum_string(b), allocator = allocator)
	}
	for i in 0 ..< input.MAX_PAD_BUTTONS {
		if input.gamepad_pressed(input.Gamepad_Button(i)) do return fmt.aprintf("pad:%s", reflect.enum_string(input.Gamepad_Button(i)), allocator = allocator)
	}
	return ""
}

Control_Kind :: enum u8 {
	None,
	Key,
	Mouse_Button,
	Mouse_Delta, // Axis2D
	Mouse_Wheel, // Axis
	Pad_Button,
	Pad_Axis,
	Pad_Stick,   // Axis2D: LEFT_STICK or RIGHT_STICK
}

Control :: struct {
	kind: Control_Kind,
	key: input.Key,
	button: input.Mouse_Button,
	pad_button: input.Gamepad_Button,
	pad_axis: input.Gamepad_Axis, // the X axis of a stick
}

// Reads a control name. The part after the colon is the key's scancode name,
// the mouse button, or the gamepad button or axis, as SDL names them.
key_parse :: proc(s: string) -> (c: Control, ok: bool) {
	colon := strings.index_byte(s, ':')
	if colon < 0 do return {}, false
	dev, name := s[:colon], s[colon + 1:]
	switch dev {
	case "key":
		k, kok := reflect.enum_from_name(input.Key, name)
		if !kok do return {}, false
		return Control{kind = .Key, key = k}, true
	case "mouse":
		switch name {
		case "Delta": return Control{kind = .Mouse_Delta}, true
		case "Wheel": return Control{kind = .Mouse_Wheel}, true
		}
		b, bok := reflect.enum_from_name(input.Mouse_Button, name)
		if !bok do return {}, false
		return Control{kind = .Mouse_Button, button = b}, true
	case "pad":
		switch name {
		case "LEFT_STICK":  return Control{kind = .Pad_Stick, pad_axis = .LEFTX}, true
		case "RIGHT_STICK": return Control{kind = .Pad_Stick, pad_axis = .RIGHTX}, true
		}
		if a, aok := reflect.enum_from_name(input.Gamepad_Axis, name); aok && a != .INVALID {
			return Control{kind = .Pad_Axis, pad_axis = a}, true
		}
		if b, bok := reflect.enum_from_name(input.Gamepad_Button, name); bok && b != .INVALID {
			return Control{kind = .Pad_Button, pad_button = b}, true
		}
	}
	return {}, false
}

// --- The runtime ------------------------------------------------------------------

@(private = "file")
_Binding :: struct {
	key: Control,
	modifier:    Modifier,
	scalar:   f32,
}

@(private = "file")
_Action :: struct {
	name:      string,
	value_type:      Value_Type,
	consume_input:  bool,
	dead_zone: f32,
	mappings:  []_Binding,
	frame:     _Value,
	fixed:     _Value,
}

@(private = "file")
_Value :: struct {
	down, pressed, released: bool,
	value: [2]f32,
}

@(private = "file")
_Map :: struct {
	name:     string,
	priority: int,
	consume:  Consume_Input,
	actions:  []_Action,
	pushed:   bool,
}

@(private = "file")
_rt: struct {
	contexts:   []_Map,
	built:  bool,
	guid:   engine.Asset_GUID,
	// The pushed maps in resolution order: priority descending, a later push
	// first among equals.
	stack:  [dynamic]int,
	pushes: int,
}

// An action, resolved once from its map and action names (action_id).
Action_Id :: struct {
	map_index, action_index: int,
}

@(private = "file") _settings_loaded: bool

@(private = "file")
// Builds the runtime from the asset the Input setting names, and rebuilds it
// when the setting changes (the Project Settings window writes the var), so
// a switch of asset reaches the game at once. A cheap check otherwise.
_ensure_built :: proc() {
	if !_settings_loaded {
		_settings_loaded = true
		engine.project_settings_load("Input", &input_settings)
	}
	if _rt.built && _rt.guid == input_settings.actions do return
	src: Input_Actions
	ok: bool
	if input_settings.actions != {} do src, ok = engine.asset_load_as(input_settings.actions, Input_Actions)
	if !ok && input_settings.actions != {} do log.warningf("[Input] the Input setting names no readable Input_Actions asset")
	defer cleanup_Input_Actions(&src)
	actions_install(src)
	_rt.guid = input_settings.actions
}

// Builds the runtime from `src`: the contexts the game pushes and reads. The
// project's asset installs itself on first use, a game may install its own.
// A context that was pushed stays pushed when `src` still has its name, so
// an edit of the asset during play keeps the game's stack.
actions_install :: proc(src: Input_Actions) {
	context.allocator = runtime.default_allocator()
	pushed := make([dynamic]string, context.temp_allocator)
	for s in _rt.stack do append(&pushed, strings.clone(_rt.contexts[s].name, context.temp_allocator))
	// The actions' states survive by name, so an edit during play is no
	// release and press of every held action.
	_Saved :: struct { context_name, action: string, frame, fixed: _Value }
	saved := make([dynamic]_Saved, context.temp_allocator)
	for &m in _rt.contexts {
		for &a in m.actions do append(&saved, _Saved{strings.clone(m.name, context.temp_allocator), strings.clone(a.name, context.temp_allocator), a.frame, a.fixed})
	}
	defer {
		for name in pushed {
			for &m in _rt.contexts do if m.name == name { context_push(name); break }
		}
		for sv in saved {
			for &m in _rt.contexts {
				if m.name != sv.context_name do continue
				for &a in m.actions do if a.name == sv.action { a.frame = sv.frame; a.fixed = sv.fixed }
			}
		}
	}
	_rt_destroy()
	_rt.contexts = make([]_Map, len(src.contexts))
	for m, i in src.contexts {
		rm := &_rt.contexts[i]
		rm.name = strings.clone(m.name)
		rm.priority = m.priority
		rm.consume = m.consume
		rm.actions = make([]_Action, len(m.actions))
		for a, j in m.actions {
			ra := &rm.actions[j]
			ra.name = strings.clone(a.name)
			ra.value_type = a.value_type
			ra.consume_input = a.consume_input
			ra.dead_zone = a.dead_zone
			ra.mappings = make([]_Binding, len(a.mappings))
			for b, k in a.mappings {
				c, cok := key_parse(string(b.key))
				if !cok do log.warningf("[Input] %s/%s: unknown control %q", m.name, a.name, b.key)
				ra.mappings[k] = _Binding{key = c, modifier = b.modifier, scalar = b.scalar == 0 ? 1 : b.scalar}
			}
		}
	}
	_rt.built = true
	// Counts as the setting's asset, so the setting check does not replace a
	// runtime a game installed itself until the setting changes.
	_rt.guid = input_settings.actions
}

@(private = "file")
_rt_destroy :: proc() {
	for &m in _rt.contexts {
		delete(m.name)
		for &a in m.actions {
			delete(a.name)
			delete(a.mappings)
		}
		delete(m.actions)
	}
	delete(_rt.contexts)
	_rt.contexts = nil
	clear(&_rt.stack)
	_rt.built = false
}

// Editor hook: an open Input Actions document's current values replace the
// runtime when it is the asset the Input setting names, so an edit in the
// inspector reaches the game before it is saved. The pushed contexts stay.
actions_preview :: proc(guid: engine.Asset_GUID, a: Input_Actions) {
	_ensure_built()
	if guid != _rt.guid do return
	// The hook runs every frame the document is open: only a change rebuilds,
	// or the action states would reset each frame.
	if _matches(a) do return
	actions_install(a)
	_rt.guid = guid
}

// Whether the built runtime came from a value equal to `a`.
@(private = "file")
_matches :: proc(a: Input_Actions) -> bool {
	if !_rt.built || len(a.contexts) != len(_rt.contexts) do return false
	for m, i in a.contexts {
		rm := &_rt.contexts[i]
		if m.name != rm.name || m.priority != rm.priority || m.consume != rm.consume || len(m.actions) != len(rm.actions) do return false
		for ac, j in m.actions {
			ra := &rm.actions[j]
			if ac.name != ra.name || ac.value_type != ra.value_type || ac.consume_input != ra.consume_input || ac.dead_zone != ra.dead_zone || len(ac.mappings) != len(ra.mappings) do return false
			for km, k in ac.mappings {
				rb := &ra.mappings[k]
				c, _ := key_parse(string(km.key))
				if c != rb.key || km.modifier != rb.modifier || (km.scalar == 0 ? 1 : km.scalar) != rb.scalar do return false
			}
		}
	}
	return true
}

// Forgets the built runtime: the next use builds it again from the setting.
// The asset file changed, or the game stopped.
actions_reset :: proc() {
	context.allocator = runtime.default_allocator()
	_rt_destroy()
	_settings_loaded = false
}

@(init)
_register :: proc "contextless" () {
	context = runtime.default_context()
	// Undo, multi-edit and the inspector's picker rows write a field back from
	// JSON through its pointer type: every field type of the asset.
	engine.register_pointer_type(Key_Name)
	engine.register_pointer_type(Modifier)
	engine.register_pointer_type(Value_Type)
	engine.register_pointer_type(Consume_Input)
	engine.register_pointer_type(Key_Mapping)
	engine.register_pointer_type(Action)
	engine.register_pointer_type(Mapping_Context)
	// The active asset's file changed: rebuild from it, keeping the stack.
	engine.asset_db_add_evict_hook(proc(path: string) {
		if !strings.has_suffix(path, ".asset") do return
		guid, ok := engine.asset_db_get_guid(path)
		if !ok || !_rt.built || engine.Asset_GUID(guid) != _rt.guid do return
		src, lok := engine.asset_load_as(_rt.guid, Input_Actions)
		if !lok do return
		defer cleanup_Input_Actions(&src)
		actions_install(src)
	})
}

// The game stops: no map stays pushed into the next run.
@(phase={key=engine.Phase.ExitingPlayMode, mode=Editor})
_stop :: proc() {
	actions_reset()
}

// Resolves an action by its map's and its own name. Panics on a name the
// asset lacks: game code resolves its actions once at startup, so a typo
// stops the game there.
action_id :: proc(map_name, action_name: string) -> Action_Id {
	_ensure_built()
	for &m, i in _rt.contexts {
		if m.name != map_name do continue
		for &a, j in m.actions {
			if a.name == action_name do return {i, j}
		}
		fmt.panicf("input_actions: map %q has no action %q", map_name, action_name)
	}
	fmt.panicf("input_actions: the Input Actions asset has no map %q", map_name)
}

// Pushes a map: its actions resolve from now on, and it takes its controls
// from the maps below it. Pushing a pushed map does nothing.
context_push :: proc(name: string) {
	_ensure_built()
	context.allocator = runtime.default_allocator()
	for &m, i in _rt.contexts {
		if m.name != name do continue
		if m.pushed do return
		m.pushed = true
		append(&_rt.stack, i)
		_stack_sort()
		return
	}
	fmt.panicf("input_actions: the Input Actions asset has no map %q", name)
}

// Pops a map: its actions read as released and zero, the maps below see
// their controls again.
context_pop :: proc(name: string) {
	_ensure_built()
	for &m, i in _rt.contexts {
		if m.name != name || !m.pushed do continue
		m.pushed = false
		for s, k in _rt.stack {
			if s == i {
				ordered_remove(&_rt.stack, k)
				break
			}
		}
		for &a in m.actions {
			a.frame = {}
			a.fixed = {}
		}
		return
	}
}

context_pushed :: proc(name: string) -> bool {
	_ensure_built()
	for &m in _rt.contexts do if m.name == name do return m.pushed
	return false
}

// The pushed maps from the top down, for a debug view.
contexts_pushed :: proc(allocator := context.temp_allocator) -> []string {
	_ensure_built()
	out := make([]string, len(_rt.stack), allocator)
	for s, i in _rt.stack do out[i] = _rt.contexts[s].name
	return out
}

// Every mapping context of the asset, pushed or not, for a debug view.
Context_Info :: struct {
	name:     string,
	priority: int,
	consume:  Consume_Input,
	pushed:   bool,
}

contexts_all :: proc(allocator := context.temp_allocator) -> []Context_Info {
	_ensure_built()
	out := make([]Context_Info, len(_rt.contexts), allocator)
	for &m, i in _rt.contexts do out[i] = {m.name, m.priority, m.consume, m.pushed}
	return out
}

@(private = "file")
_stack_sort :: proc() {
	// Insertion sort by priority descending, stable so a later push of the
	// same priority goes above an earlier one.
	for i in 1 ..< len(_rt.stack) {
		for j := i; j > 0 && _rt.contexts[_rt.stack[j]].priority >= _rt.contexts[_rt.stack[j - 1]].priority; j -= 1 {
			if _rt.contexts[_rt.stack[j]].priority == _rt.contexts[_rt.stack[j - 1]].priority && j != i do break
			_rt.stack[j], _rt.stack[j - 1] = _rt.stack[j - 1], _rt.stack[j]
		}
	}
}

// --- Reads --------------------------------------------------------------------------

down :: proc(id: Action_Id) -> bool { return _rt.contexts[id.map_index].actions[id.action_index].frame.down }
pressed :: proc(id: Action_Id) -> bool { return _rt.contexts[id.map_index].actions[id.action_index].frame.pressed }
released :: proc(id: Action_Id) -> bool { return _rt.contexts[id.map_index].actions[id.action_index].frame.released }
value :: proc(id: Action_Id) -> f32 { return _rt.contexts[id.map_index].actions[id.action_index].frame.value.x }
value2 :: proc(id: Action_Id) -> [2]f32 { return _rt.contexts[id.map_index].actions[id.action_index].frame.value }

down_fixed :: proc(id: Action_Id) -> bool { return _rt.contexts[id.map_index].actions[id.action_index].fixed.down }
pressed_fixed :: proc(id: Action_Id) -> bool { return _rt.contexts[id.map_index].actions[id.action_index].fixed.pressed }
released_fixed :: proc(id: Action_Id) -> bool { return _rt.contexts[id.map_index].actions[id.action_index].fixed.released }
value_fixed :: proc(id: Action_Id) -> f32 { return _rt.contexts[id.map_index].actions[id.action_index].fixed.value.x }
value2_fixed :: proc(id: Action_Id) -> [2]f32 { return _rt.contexts[id.map_index].actions[id.action_index].fixed.value }

// --- Debug view -------------------------------------------------------------------

// One action of a pushed context, with its frame values, for the debug
// window: `blocked` when every key of the action is consumed by a context
// above, so the action cannot answer.
Debug_Row :: struct {
	context_name: string,
	action:       string,
	value_type:   Value_Type,
	down, pressed, released: bool,
	value:        [2]f32,
	keys:         string, // the mapped keys, comma separated
	blocked:      bool,
}

// The pushed contexts' actions from the top down. Temp-allocated.
debug_rows :: proc(allocator := context.temp_allocator) -> []Debug_Row {
	_ensure_built()
	out := make([dynamic]Debug_Row, allocator)
	consumed: _Consumed
	for s in _rt.stack {
		m := &_rt.contexts[s]
		for &a in m.actions {
			keys := make([dynamic]string, allocator)
			blocked := len(a.mappings) > 0
			for b in a.mappings {
				if !_consumed(&consumed, b.key) do blocked = false
			}
			for b in a.mappings do append(&keys, _key_string(b.key, allocator))
			append(&out, Debug_Row{
				context_name = m.name, action = a.name, value_type = a.value_type,
				down = a.frame.down, pressed = a.frame.pressed, released = a.frame.released, value = a.frame.value,
				keys = strings.join(keys[:], ", ", allocator), blocked = blocked,
			})
		}
		if m.consume == .All {
			consumed.all = true
		} else {
			for &a in m.actions {
				if !a.consume_input do continue
				for b in a.mappings do _consume(&consumed, b.key)
			}
		}
	}
	return out[:]
}

@(private = "file")
_key_string :: proc(c: Control, allocator: runtime.Allocator) -> string {
	switch c.kind {
	case .None:         return "?"
	case .Key:          return fmt.aprintf("key:%v", c.key, allocator = allocator)
	case .Mouse_Button: return fmt.aprintf("mouse:%v", c.button, allocator = allocator)
	case .Mouse_Delta:  return "mouse:Delta"
	case .Mouse_Wheel:  return "mouse:Wheel"
	case .Pad_Button:   return fmt.aprintf("pad:%v", c.pad_button, allocator = allocator)
	case .Pad_Axis:     return fmt.aprintf("pad:%v", c.pad_axis, allocator = allocator)
	case .Pad_Stick:    return c.pad_axis == .LEFTX ? "pad:LEFT_STICK" : "pad:RIGHT_STICK"
	}
	return "?"
}

// --- Resolution ---------------------------------------------------------------------

// Before every game update: the frame values.
@(update={order=-10000})
actions_resolve_frame :: proc(dt: f32) {
	_resolve(false)
}

// Before every fixed update: the tick values.
@(fixed_update={order=-10000})
actions_resolve_fixed :: proc(dt: f32) {
	_resolve(true)
}

// A control the maps above consumed. Keys and buttons by their index, the
// mouse delta, wheel and pad axes by kind.
@(private = "file")
_Consumed :: struct {
	keys:        [input.MAX_KEYS]bool,
	mouse:       [input.Mouse_Button]bool,
	pad_buttons: [input.MAX_PAD_BUTTONS]bool,
	pad_axes:    [input.MAX_PAD_AXES]bool,
	delta, wheel, all: bool,
}

@(private = "file")
_consumed :: proc(c: ^_Consumed, ctl: Control) -> bool {
	if c.all do return true
	switch ctl.kind {
	case .None:         return false
	case .Key:          return c.keys[int(ctl.key)]
	case .Mouse_Button: return c.mouse[ctl.button]
	case .Mouse_Delta:  return c.delta
	case .Mouse_Wheel:  return c.wheel
	case .Pad_Button:   return c.pad_buttons[int(ctl.pad_button)]
	case .Pad_Axis:     return c.pad_axes[int(ctl.pad_axis)]
	case .Pad_Stick:    return c.pad_axes[int(ctl.pad_axis)] || c.pad_axes[int(ctl.pad_axis) + 1]
	}
	return false
}

@(private = "file")
_consume :: proc(c: ^_Consumed, ctl: Control) {
	switch ctl.kind {
	case .None:
	case .Key:          c.keys[int(ctl.key)] = true
	case .Mouse_Button: c.mouse[ctl.button] = true
	case .Mouse_Delta:  c.delta = true
	case .Mouse_Wheel:  c.wheel = true
	case .Pad_Button:   c.pad_buttons[int(ctl.pad_button)] = true
	case .Pad_Axis:     c.pad_axes[int(ctl.pad_axis)] = true
	case .Pad_Stick:
		c.pad_axes[int(ctl.pad_axis)] = true
		c.pad_axes[int(ctl.pad_axis) + 1] = true
	}
}

@(private = "file")
_resolve :: proc(fixed: bool) {
	_ensure_built()
	consumed: _Consumed
	for s in _rt.stack {
		m := &_rt.contexts[s]
		for &a in m.actions {
			v := fixed ? &a.fixed : &a.frame
			was_down := v.down
			sum: [2]f32
			any_down := false
			for b in a.mappings {
				if _consumed(&consumed, b.key) do continue
				raw, d := _control_read(b.key, fixed)
				any_down ||= d
				switch b.modifier {
				case .Whole:
					if b.key.kind == .Pad_Stick || b.key.kind == .Mouse_Delta {
						sum += raw * b.scalar
					} else {
						sum.x += raw.x * b.scalar
					}
				case .Positive: if d do sum.x += b.scalar
				case .Negative: if d do sum.x -= b.scalar
				case .Up:       if d do sum.y += b.scalar
				case .Down:     if d do sum.y -= b.scalar
				case .Left:     if d do sum.x -= b.scalar
				case .Right:    if d do sum.x += b.scalar
				}
			}
			switch a.value_type {
			case .Digital:
				v.down = any_down
				v.value = {any_down ? 1 : 0, 0}
			case .Axis1D:
				if math.abs(sum.x) < a.dead_zone do sum.x = 0
				v.value = {sum.x, 0}
				v.down = sum.x != 0
			case .Axis2D:
				if math.sqrt(sum.x * sum.x + sum.y * sum.y) < a.dead_zone do sum = {}
				v.value = sum
				v.down = sum != {}
			}
			v.pressed = v.down && !was_down
			v.released = !v.down && was_down
		}
		// What the maps below no longer see.
		if m.consume == .All {
			consumed.all = true
		} else {
			for &a in m.actions {
				if !a.consume_input do continue
				for b in a.mappings do _consume(&consumed, b.key)
			}
		}
	}
}

// A control's value and whether it counts as down: a key or button by its
// state, an axis beyond half travel, the mouse delta and wheel when moving.
@(private = "file")
_control_read :: proc(c: Control, fixed: bool) -> (v: [2]f32, down: bool) {
	switch c.kind {
	case .None:
	case .Key:
		down = fixed ? input.key_down_fixed(c.key) : input.key_down(c.key)
		v.x = down ? 1 : 0
	case .Mouse_Button:
		down = fixed ? input.mouse_down_fixed(c.button) : input.mouse_down(c.button)
		v.x = down ? 1 : 0
	case .Mouse_Delta:
		v = input.mouse_delta()
		down = v != {}
	case .Mouse_Wheel:
		v.x = input.wheel()
		down = v.x != 0
	case .Pad_Button:
		down = fixed ? input.gamepad_down_fixed(c.pad_button) : input.gamepad_down(c.pad_button)
		v.x = down ? 1 : 0
	case .Pad_Axis:
		v.x = input.gamepad_axis(c.pad_axis)
		down = math.abs(v.x) > 0.5
	case .Pad_Stick:
		// SDL's Y is down-positive: up is positive here, as the key
		// composites and the engine's Y.
		v = {input.gamepad_axis(c.pad_axis), -input.gamepad_axis(input.Gamepad_Axis(int(c.pad_axis) + 1))}
		down = math.abs(v.x) > 0.5 || math.abs(v.y) > 0.5
	}
	return
}
