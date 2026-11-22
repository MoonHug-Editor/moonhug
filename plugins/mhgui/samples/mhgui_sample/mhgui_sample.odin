package mhgui_sample

// Sample content for the mhgui plugin (plugins/mhgui/docs/_index.md).
// assets/ui_demo.scene is one overlay canvas with a captioned panel per
// feature. The Game window shows it without Play.
//
// - UiShape: a card with a soft shadow, a button with a gradient and a border,
//   a pill, a circle, a radius per corner, an outline with no fill, an inset
//   field with an inner shadow and a glow. Under them, a row of twelve
//   chips with the same values, which share one draw call.
//
// - UiMask: a viewport that cuts a circle, a bar and a line of text: with
//   round corners, turned, a circle, with a soft edge, and one mask in
//   another.
// - A scroll view, live while the game plays: eight Button rows in a masked
//   viewport, scrolled by a drag, the wheel or the bar.
// - Controls, live while the game plays: a Slider and three Toggles of a
//   ToggleGroup.
// - Layout: a row with a flexible child, a bubble sized to its text, a
//   picture kept at a ratio in its frame, and a panel a CanvasGroup fades
//   and switches off.
// - Pointer events, live while the game plays: a card that the UIDemoDrag
//   script (ui_demo.odin) drags, taking its events with
//   @(comp_on_pointer_ui), and a Button whose graphic is a UiShape.
//
// The scene is generated (the moonhug-mhgui-demo-scene skill), not edited by
// hand.

// Load-bearing: prebuild discovers packages by scanned DECLARATIONS — a file
// with only a package clause is invisible to it.
MHGUI_SAMPLE :: true
