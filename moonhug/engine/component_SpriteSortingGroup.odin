package engine

// Unity's SortingGroup: every sprite in this transform's subtree sorts as ONE
// unit against sprites outside it, using THIS component's layer/order and the
// group root's view depth; members keep sorting among themselves by their own
// keys. Nested groups sort as units inside their outer group (up to
// SPRITE_SORT_LEVELS - 1 nesting levels; deeper groups are ignored with the
// innermost ones winning). Resolution happens in the per-view scene-tree pass
// in sprite_sort.odin.
@(component)
@(typ_guid={guid = "2291f857-d2ff-409d-96df-1d87713fdcc2"})
SpriteSortingGroup :: struct {
	using base: CompData `inspect:"-"`,
	sorting_layer:  i32,
	order_in_layer: i32,
}
