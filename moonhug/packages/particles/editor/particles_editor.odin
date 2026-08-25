package particles_editor

// Editor-only half of the particles package: the ParticleSystem inspector
// wrapper draws the shared Sprite object row (inspector.sprite_ref_row) for
// the hidden PPtr field. Never compiled into the app.

import "moonhug:engine"
import "moonhug:editor/inspector"
import particles "moonhug:packages/particles"

@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
particles_inspector_install :: proc() {
	inspector.add_component_wrapper(typeid_of(particles.ParticleSystem), _particle_system_inspector)
}

_particle_system_inspector :: proc(ctx: ^inspector.Component_Ctx) {
	inspector.draw(ctx)
	ps := cast(^particles.ParticleSystem)ctx.ptr
	if inspector.sprite_ref_row("Sprite", &ps.sprite) {
		inspector.mark_inspector_changed()
		inspector.record_nested_override(&ps.sprite, typeid_of(engine.PPtr), "sprite", true)
	}
}
