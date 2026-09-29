package tests

// Every @(typ_guid) type that OWNS heap memory must have a cleanup proc
// registered: components, assets and settings alike.
//
// `engine.type_cleanup` dispatches through core's lifecycle table, which the
// generator fills from a proc named `cleanup_<TypeName>`. A type holding a
// [dynamic] or a string without one leaks that memory every time its value is
// replaced underneath it — undo calls type_cleanup before unmarshalling a
// restored value, reset_T calls it before the defaults, and the inspector's
// documents call it when a document is rebuilt or closed.
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

@(test)
test_every_owning_type_has_cleanup :: proc(t: ^testing.T) {
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
		// A transform is not a value: transform_destroy frees it.
		if key == .Transform do continue
		if !_type_owns_heap(ti) do continue

		if !engine.type_has_cleanup(key) {
			append(&missing, fmt.tprintf("%v", tid))
		}
	}

	if len(missing) > 0 {
		testing.expectf(
			t, false,
			"types own heap memory but have no cleanup_<Type> proc, so undo, reset and document release leak their allocations: %v",
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
