package editor

import "core:c"
import rl "vendor:raylib"
import im "../../external/odin-imgui"

keys_down_prev: map[rl.KeyboardKey]bool
mods_down_prev: [4]bool // Ctrl, Shift, Alt, Super — feed ImGuiMod_* so io.KeyMods/shortcuts work

@(private)
raylib_key_to_imgui :: proc(rl_key: rl.KeyboardKey) -> (im_key: im.Key, ok: bool) {
    #partial switch rl_key {
    case .SPACE:       return .Space, true
    case .ESCAPE:      return .Escape, true
    case .ENTER:       return .Enter, true
    case .TAB:         return .Tab, true
    case .BACKSPACE:   return .Backspace, true
    case .INSERT:      return .Insert, true
    case .DELETE:      return .Delete, true
    case .RIGHT:       return .RightArrow, true
    case .LEFT:        return .LeftArrow, true
    case .DOWN:       return .DownArrow, true
    case .UP:          return .UpArrow, true
    case .PAGE_UP:     return .PageUp, true
    case .PAGE_DOWN:   return .PageDown, true
    case .HOME:        return .Home, true
    case .END:         return .End, true
    case .LEFT_SHIFT:  return .LeftShift, true
    case .RIGHT_SHIFT: return .RightShift, true
    case .LEFT_CONTROL: return .LeftCtrl, true
    case .RIGHT_CONTROL: return .RightCtrl, true
    case .LEFT_ALT:    return .LeftAlt, true
    case .RIGHT_ALT:   return .RightAlt, true
    case .LEFT_SUPER:  return .LeftSuper, true
    case .RIGHT_SUPER: return .RightSuper, true
    case .KB_MENU:     return .Menu, true
    case .APOSTROPHE:  return .Apostrophe, true
    case .COMMA:       return .Comma, true
    case .MINUS:       return .Minus, true
    case .PERIOD:      return .Period, true
    case .SLASH:       return .Slash, true
    case .SEMICOLON:   return .Semicolon, true
    case .EQUAL:       return .Equal, true
    case .LEFT_BRACKET: return .LeftBracket, true
    case .BACKSLASH:   return .Backslash, true
    case .RIGHT_BRACKET: return .RightBracket, true
    case .GRAVE:       return .GraveAccent, true
    case .CAPS_LOCK:   return .CapsLock, true
    case .SCROLL_LOCK: return .ScrollLock, true
    case .NUM_LOCK:    return .NumLock, true
    case .PRINT_SCREEN: return .PrintScreen, true
    case .PAUSE:       return .Pause, true
    case .F1:          return .F1, true
    case .F2:          return .F2, true
    case .F3:          return .F3, true
    case .F4:          return .F4, true
    case .F5:          return .F5, true
    case .F6:          return .F6, true
    case .F7:          return .F7, true
    case .F8:          return .F8, true
    case .F9:          return .F9, true
    case .F10:         return .F10, true
    case .F11:         return .F11, true
    case .F12:         return .F12, true
    case .KP_0:        return .Keypad0, true
    case .KP_1:        return .Keypad1, true
    case .KP_2:        return .Keypad2, true
    case .KP_3:        return .Keypad3, true
    case .KP_4:        return .Keypad4, true
    case .KP_5:        return .Keypad5, true
    case .KP_6:        return .Keypad6, true
    case .KP_7:        return .Keypad7, true
    case .KP_8:        return .Keypad8, true
    case .KP_9:        return .Keypad9, true
    case .KP_DECIMAL:  return .KeypadDecimal, true
    case .KP_DIVIDE:   return .KeypadDivide, true
    case .KP_MULTIPLY: return .KeypadMultiply, true
    case .KP_SUBTRACT: return .KeypadSubtract, true
    case .KP_ADD:      return .KeypadAdd, true
    case .KP_ENTER:    return .KeypadEnter, true
    case .KP_EQUAL:    return .KeypadEqual, true
    case .ZERO:        return ._0, true
    case .ONE:         return ._1, true
    case .TWO:         return ._2, true
    case .THREE:       return ._3, true
    case .FOUR:        return ._4, true
    case .FIVE:        return ._5, true
    case .SIX:         return ._6, true
    case .SEVEN:       return ._7, true
    case .EIGHT:       return ._8, true
    case .NINE:        return ._9, true
    case .A:           return .A, true
    case .B:           return .B, true
    case .C:           return .C, true
    case .D:           return .D, true
    case .E:           return .E, true
    case .F:           return .F, true
    case .G:           return .G, true
    case .H:           return .H, true
    case .I:           return .I, true
    case .J:           return .J, true
    case .K:           return .K, true
    case .L:           return .L, true
    case .M:           return .M, true
    case .N:           return .N, true
    case .O:           return .O, true
    case .P:           return .P, true
    case .Q:           return .Q, true
    case .R:           return .R, true
    case .S:           return .S, true
    case .T:           return .T, true
    case .U:           return .U, true
    case .V:           return .V, true
    case .W:           return .W, true
    case .X:           return .X, true
    case .Y:           return .Y, true
    case .Z:           return .Z, true
    case .KEY_NULL:
        return .None, false
    case .BACK, .MENU, .VOLUME_UP, .VOLUME_DOWN:
        return .None, false
    case:
        return .None, false
    }
}

KEYS_TO_POLL :: []rl.KeyboardKey{
    .SPACE, .ESCAPE, .ENTER, .TAB, .BACKSPACE, .INSERT, .DELETE,
    .RIGHT, .LEFT, .DOWN, .UP, .PAGE_UP, .PAGE_DOWN, .HOME, .END,
    .LEFT_SHIFT, .RIGHT_SHIFT, .LEFT_CONTROL, .RIGHT_CONTROL,
    .LEFT_ALT, .RIGHT_ALT, .LEFT_SUPER, .RIGHT_SUPER, .KB_MENU,
    .APOSTROPHE, .COMMA, .MINUS, .PERIOD, .SLASH, .SEMICOLON, .EQUAL,
    .LEFT_BRACKET, .BACKSLASH, .RIGHT_BRACKET, .GRAVE,
    .CAPS_LOCK, .SCROLL_LOCK, .NUM_LOCK, .PRINT_SCREEN, .PAUSE,
    .ZERO, .ONE, .TWO, .THREE, .FOUR, .FIVE, .SIX, .SEVEN, .EIGHT, .NINE,
    .A, .B, .C, .D, .E, .F, .G, .H, .I, .J, .K, .L, .M, .N, .O, .P, .Q, .R, .S, .T, .U, .V, .W, .X, .Y, .Z,
    .F1, .F2, .F3, .F4, .F5, .F6, .F7, .F8, .F9, .F10, .F11, .F12,
    .KP_0, .KP_1, .KP_2, .KP_3, .KP_4, .KP_5, .KP_6, .KP_7, .KP_8, .KP_9,
    .KP_DECIMAL, .KP_DIVIDE, .KP_MULTIPLY, .KP_SUBTRACT, .KP_ADD, .KP_ENTER, .KP_EQUAL,
}

// ImGui uses ImGuiMod_XXX (not LeftCtrl/RightCtrl) for io.KeyMods and shortcut matching. We must submit them.
@(private)
update_imgui_key_modifiers :: proc(io: ^im.IO) {
    mods_now: [4]bool = {
        rl.IsKeyDown(.LEFT_CONTROL)  || rl.IsKeyDown(.RIGHT_CONTROL),
        rl.IsKeyDown(.LEFT_SHIFT)   || rl.IsKeyDown(.RIGHT_SHIFT),
        rl.IsKeyDown(.LEFT_ALT)     || rl.IsKeyDown(.RIGHT_ALT),
        rl.IsKeyDown(.LEFT_SUPER)   || rl.IsKeyDown(.RIGHT_SUPER),
    }
    mod_keys: [4]im.Key = {
        im.Key.ImGuiMod_Ctrl,
        im.Key.ImGuiMod_Shift,
        im.Key.ImGuiMod_Alt,
        im.Key.ImGuiMod_Super,
    }
    for i in 0 ..< 4 {
        if mods_now[i] != mods_down_prev[i] {
            im.IO_AddKeyEvent(io, mod_keys[i], mods_now[i])
            mods_down_prev[i] = mods_now[i]
        }
    }
}

update_imgui_keyboard_input :: proc() {
    io := im.GetIO()
    if io == nil do return

    for ch := rl.GetCharPressed(); ch != 0; ch = rl.GetCharPressed() {
        im.IO_AddInputCharacter(io, cast(c.uint)ch)
    }

    // So io.KeyMods is set and shortcuts (e.g. Ctrl+S) work
    update_imgui_key_modifiers(io)

    if keys_down_prev == nil {
        keys_down_prev = make(map[rl.KeyboardKey]bool)
    }

    for rl_key in KEYS_TO_POLL {
        im_key, ok := raylib_key_to_imgui(rl_key)
        if !ok do continue
        down := rl.IsKeyDown(rl_key)
        prev, in_map := keys_down_prev[rl_key]
        if !in_map || prev != down {
            im.IO_AddKeyEvent(io, im_key, down)
            keys_down_prev[rl_key] = down
        }
    }
}
