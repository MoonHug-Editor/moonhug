package viewport

// The scene view's tool mode: the tool (Q W E R T), the gizmo space and the
// gizmo pivot. The shell sets them from its overlays and keys, the engine's
// transform tool reads them.

import "moonhug:editor/handles"

// The scene view's tool (handles.Tool): Q selection only, W E R the
// transform gizmo, T the selection's own handles in place of the gizmo.
Gizmo_Mode :: handles.Tool

gizmo_mode: Gizmo_Mode = .Translate

// Gizmo axis orientation: Global = world axes, Local = the object's rotated
// axes. Scale ignores this: it always composes in local space.
Gizmo_Space :: enum {
	Global,
	Local,
}

gizmo_space: Gizmo_Space = .Global

// Gizmo position: the active object's pivot, or the centroid of the selected
// top-level objects (the pivot average stands in for the combined bounds
// center).
Gizmo_Pivot :: enum {
	Pivot,
	Center,
}

gizmo_pivot: Gizmo_Pivot = .Pivot
