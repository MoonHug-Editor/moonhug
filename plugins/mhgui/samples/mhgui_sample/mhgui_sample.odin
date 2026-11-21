package mhgui_sample

// Sample content for the mhgui plugin (plugins/mhgui/docs/_index.md).
// assets/ui_demo.scene is one overlay canvas with a captioned panel per
// feature. The Game window shows it without Play.
//
// - Shape: a card with a soft shadow, a button with a gradient and a border,
//   a pill, a circle, a radius per corner, an outline with no fill, an inset
//   field with an inner shadow and a glow. Under them, a row of twelve
//   chips with the same values, which share one draw call.
//
// The scene is generated (the moonhug-mhgui-demo-scene skill), not edited by
// hand.

// Load-bearing: prebuild discovers packages by scanned DECLARATIONS — a file
// with only a package clause is invisible to it.
MHGUI_SAMPLE :: true
