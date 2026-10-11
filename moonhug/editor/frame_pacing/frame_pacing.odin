package frame_pacing

// The editor's frame-rate setting, read by moonhug/editor/frame_pacing.odin.
// A package of its own so the inspector's generated field tags can name it.

Frame_Pacing :: struct {
	max_fps:       int `decor:min(10) decor:help(text="The most frames the editor draws per second. A display refreshing faster still shows this many.")`,
	idle_fps:      int `decor:min(1) decor:help(text="Frames per second while idle: no input for half a second and nothing playing. Any input wakes the editor at once.")`,
	throttle_idle: bool `decor:help(text="Draw at the idle rate while idle. Off draws at the full rate all the time.")`,
}

@(user_settings={name="Frame Pacing", tab="Performance"})
settings := Frame_Pacing{max_fps = 60, idle_fps = 4, throttle_idle = true}
