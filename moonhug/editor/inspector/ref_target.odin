package inspector

// The `ref:` field tag, resolved.
//
// A reference field says what may go in it with `ref:"..."`, and the value is
// a comma list where each item is either a component TYPE by name or a
// CAPABILITY TAG with an `@` sigil:
//
//     ref:"Animation"            one type
//     ref:"Animation,AudioSource" several types
//     ref:"@Output"              every type declaring ref_tags="Output"
//     ref:"Animation,@Output"    both forms, unioned
//
// One rule for every form, so there is never a second syntax to learn. The
// `@` form is the extensible one: a plugin marks its own component
// (`@(component={ref_tags="Output"})`) and it appears in a field that never
// heard of it — and drops out again when the plugin is disabled, because the
// set is read from the live component registry, not from a table.
//
// The three reference drawers (Ref_Local, Ref, Asset_GUID) all resolve through
// here and nowhere else.

import "core:reflect"
import "core:strings"
import engine "../../engine"

// The component keys `spec` admits, in first-mention order with duplicates
// removed. Empty for an empty spec, and for a spec naming nothing that exists —
// the drawers show "no picker" for that rather than an empty list, so a typo
// in a tag is visible instead of silent.
ref_target_keys :: proc(spec: string, allocator := context.temp_allocator) -> []engine.TypeKey {
	out := make([dynamic]engine.TypeKey, allocator)
	if strings.trim_space(spec) == "" do return out[:]

	add :: proc(out: ^[dynamic]engine.TypeKey, k: engine.TypeKey) {
		for have in out do if have == k do return
		append(out, k)
	}

	for raw in strings.split(spec, ",", context.temp_allocator) {
		item := strings.trim_space(raw)
		if item == "" do continue
		if strings.has_prefix(item, "@") {
			for k in engine.component_keys_with_ref_tag(item[1:]) do add(&out, k)
			continue
		}
		if k, ok := reflect.enum_from_name(engine.TypeKey, item); ok {
			add(&out, k)
		}
	}
	return out[:]
}

// The spec as the row shows it when its target is gone: `Missing (@Output)`,
// `Missing (Animation)`. The spec itself, not a resolved key — a tag names an
// intent, and the intent is what the author wrote.
ref_target_missing_text :: proc(spec: string) -> string {
	if strings.trim_space(spec) == "" do return "Missing"
	return strings.concatenate({"Missing (", spec, ")"}, context.temp_allocator)
}
