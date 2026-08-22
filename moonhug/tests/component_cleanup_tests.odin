package tests

// Every component that OWNS heap memory must have a cleanup proc registered.
//
// `engine.type_cleanup` dispatches through `type_cleanup_procs[key]`, which the
// generator fills from a proc named `cleanup_<TypeName>`. A component holding a
// [dynamic] or a string without one leaks that memory every time its value is
// replaced underneath it — undo calls type_cleanup before unmarshalling a
// restored value, so a single edit-then-undo cycle orphans the old allocation.
//
// The leak is silent: nothing fails, the allocation is simply never returned.
// It surfaces only as a "+++ leak" line in the test runner's memory report, on
// whichever unrelated test happened to trigger a restore — which is a slow way
// to find out. This test names the offender directly.

import "base:runtime"
import "core:fmt"
import "core:reflect"
import "core:testing"

import "../engine"

// Whether a type transitively owns heap memory: a dynamic array, a map, or a
// string anywhere inside it. Fixed arrays and nested structs are searched
// through, since owning data one level down still has to be freed.
@(private)
_type_owns_heap :: proc(ti: ^runtime.Type_Info, depth := 0) -> bool {
	if ti == nil || depth > 8 do return false
	base := runtime.type_info_base(ti)

	#partial switch v in base.variant {
	case runtime.Type_Info_Dynamic_Array:
		return true
	case runtime.Type_Info_Map:
		return true
	case runtime.Type_Info_String:
		return true
	case runtime.Type_Info_Slice:
		// A slice may point at borrowed storage, so it is not owning by itself.
		return false
	case runtime.Type_Info_Array:
		return _type_owns_heap(v.elem, depth + 1)
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(v.field_count) {
			// Runtime-only fields are still owned, so they are NOT skipped here:
			// json:"-" means "not serialized", not "not allocated".
			if _type_owns_heap(v.types[i], depth + 1) do return true
		}
		return false
	}
	return false
}

// A component embeds CompData as its first field. Assets and settings structs
// are registered types too, but they are not components and are freed by their
// own subsystems.
@(private)
_embeds_comp_data :: proc(ti: ^runtime.Type_Info) -> bool {
	base := runtime.type_info_base(ti)
	s, is_struct := base.variant.(runtime.Type_Info_Struct)
	if !is_struct || s.field_count == 0 do return false
	return s.offsets[0] == 0 && s.types[0].id == typeid_of(engine.CompData)
}

@(test)
test_every_owning_component_has_cleanup :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	missing := make([dynamic]string, context.temp_allocator)

	for key in engine.TypeKey {
		if key == engine.INVALID_TYPE_KEY do continue
		tid := engine.get_typeid_by_type_key(key)
		if tid == nil do continue

		ti := type_info_of(tid)
		if ti == nil do continue
		if !reflect.is_struct(runtime.type_info_base(ti)) do continue
		// COMPONENTS only. Assets, settings structs and serialization fixtures
		// are also registered here, but they are freed through their own
		// lifetimes (asset unload, settings reload) rather than type_cleanup.
		// A component is what embeds CompData at offset 0 — the same shape
		// comp_zero requires.
		if !_embeds_comp_data(ti) do continue
		if !_type_owns_heap(ti) do continue

		if engine.type_cleanup_procs[key] == nil {
			append(&missing, fmt.tprintf("%v", tid))
		}
	}

	if len(missing) > 0 {
		testing.expectf(
			t, false,
			"components own heap memory but have no cleanup_<Type> proc, so undo leaks their allocations on every restore: %v",
			missing[:],
		)
	}
}

// A cleanup proc has to be safe to call twice: on_destroy delegates to it, and
// undo calls it before each restore, so the same component can be cleaned more
// than once with no intervening allocation.
@(test)
test_cleanup_is_idempotent :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	tH := engine.transform_new("A")
	_, ptr := engine.transform_add_comp(tH, .MeshRenderer)
	mr := cast(^engine.MeshRenderer)ptr

	mr.materials = make([dynamic]engine.Asset_GUID)
	append(&mr.materials, engine.Asset_GUID{})

	// Twice in a row: the second call must not double-free. comp_zero at the end
	// of cleanup is what makes this safe — it clears the pointers the first call
	// released, so the nil checks short-circuit.
	engine.type_cleanup(.MeshRenderer, ptr)
	engine.type_cleanup(.MeshRenderer, ptr)

	testing.expect_value(t, len(mr.materials), 0)
}
