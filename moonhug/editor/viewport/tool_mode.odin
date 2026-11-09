package viewport

// The Scene window's tool mode: the tool (Q W E R T), the gizmo space and the
// gizmo pivot. The shell sets them from its overlays and keys, the engine's
// transform tool reads them. The space and the pivot persist (gizmo_prefs).

import "moonhug:editor/handles"

// The Scene window's tool (handles.Tool): Q selection only, W E R the
// transform gizmo, T the selection's own handles in place of the gizmo.
Gizmo_Mode :: handles.Tool

gizmo_mode: Gizmo_Mode = .Translate

// Gizmo axis orientation: Global = world axes, Local = the object's rotated
// axes. Scale ignores this: it always composes in local space.
Gizmo_Space :: enum {
	Global,
	Local,
}

// Gizmo position: the active object's pivot, or the centroid of the selected
// top-level objects (the pivot average stands in for the combined bounds
// center).
Gizmo_Pivot :: enum {
	Pivot,
	Center,
}

// What the Scene window's Pivot overlay sets, kept per developer in
// UserSettings/gizmo.json, so the gizmo comes back placed and oriented the way
// it was left. Zero is the default: world axes, at the active object's pivot.
Gizmo_Prefs :: struct {
	space: Gizmo_Space,
	pivot: Gizmo_Pivot,
}

@(user_settings={name="Gizmo"})
gizmo_prefs: Gizmo_Prefs
