package app

import "../engine"

// List of demo scenes the in-game demo menu offers. Authored in the inspector
// by dragging .scene assets into the array; app code loads/unloads them
// additively (see app/demo_menu.odin). Labels come from the asset paths.
@(component={max=1})
@(typ_guid={guid = "7cbf2edf-0283-43b3-930e-ef9546d8eed9"})
DemoMenu :: struct {
    using base: engine.CompData `inspect:"-"`,
    demos: [dynamic]engine.Asset_GUID,
}

reset_DemoMenu :: proc(comp: ^DemoMenu) {
    cleanup_DemoMenu(comp)
    comp.demos = make([dynamic]engine.Asset_GUID)
}

on_destroy_DemoMenu :: proc(comp: ^DemoMenu) {
    cleanup_DemoMenu(comp)
}

cleanup_DemoMenu :: proc(comp: ^DemoMenu) {
    if comp.demos != nil do delete(comp.demos)
    engine.comp_zero(comp)
}
