package widgets

import im "moonhug:external/odin-imgui"

// A button that toggles `on`: a filter, a padlock. On: highlighted with
// on_color (or the theme's active-button color when none given). Off: the
// theme's NORMAL button with a dimmed label: a near-black button reads as
// disabled or broken rather than toggled off. The padlocks of the inspectors
// and the Animation window are these.
toggle_button :: proc(label: cstring, on: ^bool, on_color := im.Vec4{}) {
	if on^ {
		col := on_color
		if col == {} {
			col = im.GetStyleColorVec4(im.Col.ButtonActive)^
		}
		im.PushStyleColorImVec4(.Button, col)
	} else {
		txt := im.GetStyleColorVec4(im.Col.Text)^
		im.PushStyleColorImVec4(.Text, im.Vec4{txt.x * 0.5, txt.y * 0.5, txt.z * 0.5, txt.w})
	}
	if im.Button(label) do on^ = !on^
	im.PopStyleColor()
}
