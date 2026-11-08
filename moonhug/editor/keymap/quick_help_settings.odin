package keymap

// Which tools' quick help the status bar shows (quick_help), for the person
// on this machine: the Quick Help section of the settings window, a
// @(system_settings) tab drawn and saved like every other settings tab. Its
// list's drawer is in moonhug:editor/quick_help.

import "core:slice"

Quick_Help_Settings :: struct {
	show_in_status_bar: bool `decor:tooltip(desc="While a tool runs, the flythrough for one, the status bar lists its keys in place of the last log line.")`,
	hidden_tools:       Quick_Help_Hidden `decor:tooltip(desc="Tools whose keys the status bar does not list, while the others still show.")`,
}

// The names of the tool keymaps whose quick help stays hidden. A type of its
// own, so its drawer lists the registered tool keymaps as checkboxes.
Quick_Help_Hidden :: distinct [dynamic]string

@(system_settings={name="Quick Help", tab="Quick Help"})
quick_help_settings := Quick_Help_Settings{show_in_status_bar = true}

// Whether the status bar shows the quick help of the tool keymap `name`.
quick_help_shown :: proc(name: string) -> bool {
	return quick_help_settings.show_in_status_bar && !slice.contains(quick_help_settings.hidden_tools[:], name)
}
