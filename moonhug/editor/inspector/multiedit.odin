package inspector

// Multi-object editing.
//
// The inspector draws ONE object — the active one — and knows nothing about
// selections. Multi-edit is layered on top as two ambient facts the field loop
// sets around each drawer call:
//
//   _multi_peers       the same field on the OTHER selected objects
//   current_field_mixed  whether those peers agree with the drawn value
//
// A drawer reads the mixed flag if it wants to render Unity's "—", writes the
// drawn value as it always has, and never learns a selection exists. That is
// what keeps every existing drawer — including ones outside this package —
// working unchanged: ignoring the flag shows the active object's value, which
// is exactly the pre-multiedit behavior.
//
// PROPAGATION is the other half, and it does NOT copy bytes. A field can own
// heap memory (string, dynamic array, a Ref with a resolved handle), so giving
// N objects a memcpy of one value hands them all the same backing pointer and
// the first cleanup frees it out from under the rest. Propagation instead
// serializes the committed value and unmarshals a fresh copy into each peer —
// the identical capture_json / cleanup / unmarshal / resolve sequence undo
// applies for a Value_Command, so every type undo can already round-trip
// propagates correctly, with no per-type knowledge here.
//
// Only the components the WHOLE selection shares are drawn, so a peer pointer
// always exists and always has the field. See multi_common_components.

import "base:runtime"
import "core:slice"
import engine "../../engine"
import "../undo"

// One selected object's counterpart of the object currently being drawn: the
// component instance (or transform) that holds the same fields.
//
// `base` points into a component POOL, which is a fixed array — the slot does
// not move while the component lives, so this stays valid for the frame.
//
// `array_data_offset` is what makes dynamic-array rows safe. Element storage is
// a separate heap allocation, and undo's restore FREES AND REALLOCATES it
// (write_json_value cleans up the old value before unmarshalling a new one), so
// a cached element pointer dangles the moment anything undoes. Instead of
// caching it, a rebased peer records where the array FIELD sits and re-reads
// `data` from it at the moment of use — see multi_peer_ptr.
Multi_Peer :: struct {
	base:   rawptr,         // component/transform base pointer
	handle: engine.Handle,  // undo target for edits propagated here
	scene:  ^engine.Scene,  // for rebinding reference handles after a write

	// Set only on peers rebased onto a dynamic array's elements.
	in_dynamic_array:  bool,
	array_data_offset: uintptr, // offset of the array FIELD from `base`
	array_elem_size:   int,     // to bounds-check an element offset against len

	// Prefab-instance identity, when this peer is instance content. An edit to
	// such an object is not just a value write — it records an OVERRIDE against
	// its instance, and the instance is per-object. Carrying the pair here is
	// what lets a selection mix plain objects and prefab content: each peer's
	// override lands on its own instance instead of the active object's.
	// Zero for plain scene objects, which record no override.
	nested_host: engine.Transform_Handle,
	nested_lid:  engine.Local_ID,
}

// Where this peer's copy of the field at `offset` lives, right now.
//
// For a plain peer that is base+offset. For one rebased onto a dynamic array it
// re-reads the array's `data` pointer first, so a reallocation between the
// probe and the commit cannot leave us writing into freed memory.
//
// Returns nil when the array has been emptied or shortened past the field, which
// a restore can also do.
@(private)
_multi_peer_ptr :: proc(peer: Multi_Peer, offset: uintptr) -> rawptr {
	if peer.base == nil do return nil
	if !peer.in_dynamic_array {
		return rawptr(uintptr(peer.base) + offset)
	}
	da := (^runtime.Raw_Dynamic_Array)(rawptr(uintptr(peer.base) + peer.array_data_offset))
	if da.data == nil do return nil
	// The element this offset names must still be inside the array: a restore
	// can shorten it, and rows drawn from the previous length would then reach
	// past the end.
	if peer.array_elem_size > 0 && int(offset) + peer.array_elem_size > da.len * peer.array_elem_size {
		return nil
	}
	return rawptr(uintptr(da.data) + offset)
}

@(private)
_multi_peers: []Multi_Peer

// True when the field the drawer is about to draw differs on any peer. Drawers
// render Unity's mixed-value dash from this. Per component so a partially
// agreeing vector dashes only the axes that disagree — see multi_probe_field.
current_field_mixed: bool
current_field_mixed_comps: [4]bool

// The field's value as it was when the EDIT STARTED, not as of this frame.
//
// This is what makes a vector edit fieldwise. A drawer writes through a pointer,
// so after it returns we know the new WHOLE value but not which part the user
// touched — and copying the whole thing to every peer would flatten the axes
// they never edited (drag scale.y and X/Z get overwritten too). Diffing against
// the pre-image recovers the touched components, which is the granularity Unity
// edits at.
//
// The capture point matters and is easy to get wrong. Refreshing this every
// frame the field is drawn looks right but defeats the whole mechanism: a
// commit fires on the frame the drag RELEASES, and by then this frame's capture
// already contains the drag's changes, so the diff comes back empty and the
// code silently falls back to whole-value propagation — the exact flattening
// the diff exists to prevent. So the pre-image is taken when the edit BEGINS
// (first frame the widget is active) and held until the commit consumes it.
// Set while an edit is in flight, so per-frame probes leave the pre-image alone.

// Big enough for the scalar-array fields this applies to ([4]f32 is the largest
// vector row). A field that does not fit takes the whole-value path, which is
// correct for everything except partially-edited vectors.
MULTI_PRE_EDIT_MAX :: 64

// The peers for the object being drawn. Empty for a single selection, which is
// what makes every path below a no-op then.
multi_set_peers :: proc(peers: []Multi_Peer) -> []Multi_Peer {
	prev := _multi_peers
	_multi_peers = peers
	return prev
}

multi_active :: proc() -> bool {
	return len(_multi_peers) > 0
}

// Byte offset of the object currently being drawn from the component base the
// peers point at. draw_inspector recurses into nested structs and array
// elements, so a field's offset within its immediate parent is not enough to
// find the same field on a peer — the offsets have to accumulate down the
// recursion. Set by whoever descends, restored on the way out.
@(private)
_multi_base_offset: uintptr

multi_push_offset :: proc(delta: uintptr) -> uintptr {
	prev := _multi_base_offset
	_multi_base_offset += delta
	return prev
}

multi_pop_offset :: proc(prev: uintptr) {
	_multi_base_offset = prev
}

multi_offset_of :: proc(field_ptr: rawptr, parent_ptr: rawptr) -> uintptr {
	if field_ptr == nil || parent_ptr == nil do return _multi_base_offset
	return _multi_base_offset + (uintptr(field_ptr) - uintptr(parent_ptr))
}

multi_peer_count :: proc() -> int {
	return len(_multi_peers)
}

// The current peers, for the few fields that cannot use the generic propagate
// path and must compute their own per-peer value. Rotation is the case: its
// stored quaternion is rebuilt from all three euler angles, so only the caller
// knows which axis the user moved.
multi_peers :: proc() -> []Multi_Peer {
	return _multi_peers
}

// Sets the mixed flags from values the CALLER computed, for a widget whose
// display representation is not the stored one.
//
// Rotation needs this. Its field is a quaternion but its row is three euler
// boxes, and the two do not correspond: peers that agree on the axis being
// edited still hold different quaternions because they keep their own other
// axes. Probing the quaternion therefore marks all three boxes mixed after any
// edit — every box shows the dash even though the axis you just set agrees.
//
// `differs` is per displayed component, in the row's own terms.
multi_set_mixed_components :: proc(differs: [3]bool) {
	current_field_mixed = false
	current_field_mixed_comps = {}
	for d, i in differs {
		if !d do continue
		current_field_mixed = true
		current_field_mixed_comps[i] = true
	}
}

// Clears the ambient mixed state. The field loop calls this after each drawer
// so a drawer that never had it set can't read a stale flag from the previous
// field.
multi_clear_mixed :: proc() {
	current_field_mixed = false
	current_field_mixed_comps = {}
}


multi_shutdown :: proc() {
}

// Compares `field_ptr` (offset `offset` from the drawn object's base) against
// every peer and sets the ambient mixed flags.
//
// Comparison is on the SERIALIZED value, not the raw bytes: two strings with
// equal contents live at different addresses, and a Ref carries a runtime
// handle that differs between objects while naming the same target. Byte
// equality reports both as mixed, which is wrong and — worse — is wrong only
// sometimes, so it looks like a rendering glitch.
//
// The per-component pass on top is a raw compare, and only for arrays of
// scalars ([3]f32 and friends), where element bytes are self-contained.
multi_probe_field :: proc(field_ptr: rawptr, field_tid: typeid, offset: uintptr) {
	multi_clear_mixed()
	if len(_multi_peers) == 0 || field_ptr == nil do return

	elem_size, elem_count := _scalar_array_shape(field_tid)

	self_json := undo.capture_json(field_ptr, field_tid)
	if self_json == nil do return
	defer delete(self_json)

	for peer in _multi_peers {
		peer_ptr := _multi_peer_ptr(peer, offset)
		if peer_ptr == nil do continue

		peer_json := undo.capture_json(peer_ptr, field_tid)
		if peer_json == nil do continue
		equal := slice.equal(self_json, peer_json)
		delete(peer_json)
		if equal do continue

		current_field_mixed = true

		// Which components disagree, for a vector row. A non-array field has
		// elem_count 0 and leaves the component flags clear — drawers then fall
		// back to the whole-field flag.
		for i in 0 ..< elem_count {
			if i >= len(current_field_mixed_comps) do break
			if current_field_mixed_comps[i] do continue
			a := rawptr(uintptr(field_ptr) + uintptr(i * elem_size))
			b := rawptr(uintptr(peer_ptr) + uintptr(i * elem_size))
			if !_bytes_equal(a, b, elem_size) {
				current_field_mixed_comps[i] = true
			}
		}
	}
}


// Mirrors the in-flight value onto the peers WITHOUT recording undo, so a drag
// moves the whole selection live instead of snapping to it on release.
//
// Recording is deliberately skipped: an entry per frame would bury the stack
// under hundreds of steps for one drag. The commit that ends the drag records
// the single real entry, comparing against the value the peers had when the
// edit began — which is why the pre-image has to survive the drag anyway.
//
// Fieldwise like the commit path: only the components the user has moved so far
// are mirrored, so the axes they are not touching keep each peer's own value.
// Peers' own values for the axes being previewed, captured the first frame the
// preview writes so the commit can restore them and record a real before/after.
// Which field the saved bytes belong to, so a stale preview cannot be applied
// to a different field's peers.





// Opens the undo group that a multi-edit commit lands in, and returns it.
//
// This has to be opened BEFORE the drawer's own commit fires, not inside
// multi_propagate_field. The active object's entry is pushed by the caller's
// commit detection (_undo_finalize_widget and friends), which runs first — a
// group opened afterwards would contain only the peers, leaving the active
// object as its own separate entry. That is "undo only reverts 1 of 2".
//
// Groups nest through the stack's txn_stack, so everything pushed while this is
// open lands inside it: the active object's edit, and every peer's.
//
// Safe when there is no multi-selection: it opens an empty group, and
// end_group_command drops a group with no entries, so single-object editing
// records exactly what it did before.
multi_edit_group_begin :: proc(label := "Multi Edit") -> undo.Group_Scope {
	if len(_multi_peers) == 0 do return {}
	g := undo.group_begin(label)
	// Committed unconditionally: whether anything was recorded is decided by
	// end_group_command, which discards an empty group.
	undo.group_commit(&g)
	return g
}

multi_edit_group_end :: proc(g: ^undo.Group_Scope) {
	undo.group_end(g)
}

// How one peer's edit is recorded for undo.
//
// A pooled Value_Command stores the field as an OFFSET from the component base
// and re-derives the pointer on apply (resolve_target_ptr: base + offset). That
// only works when the field actually lives inside the pool slot. An element of
// a dynamic array does not — it lives in a separate heap buffer — so
// `field_ptr - base` is the distance between two unrelated allocations, and
// applying it later writes to `base + <garbage>`.
//
// That is the material crash: setting a MeshRenderer material during a
// multi-selection recorded a nonsense offset, and the undo wrote a restored
// guid through it (SIGBUS inside asset_guid_unmarshal, at a heap-looking
// address that changed every run).
//
// So element edits record the WHOLE COMPONENT instead, via the snapshot API the
// array rows already use. Coarser, and correct.
@(private)
_Peer_Edit :: struct {
	scope:     undo.Edit_Scope,
	whole:     bool, // recorded as a component snapshot rather than a field
	pushed:    bool,
}





// Element size and count for a VECTOR ROW — a fixed array the inspector draws
// as separate per-component widgets — else (0, 0).
//
// The restriction to float arrays of 2..4 is not cosmetic, it is a correctness
// boundary. Per-component treatment is only meaningful when the user can edit
// components independently, which is exactly what the drag_floatN rows offer.
// Applying it to any array of scalars corrupts values that merely happen to BE
// arrays: Asset_GUID is a distinct [16]u8, so a byte-wise diff would propagate
// only the bytes that differ between two guids and leave a mixture that names
// neither asset. Same hazard for any [N]u8 identifier or packed field.
//
// Non-vector fields fall through to whole-value propagation, which is correct
// for them — they are written whole by their drawer.
@(private)
_scalar_array_shape :: proc(tid: typeid) -> (elem_size: int, elem_count: int) {
	ti := runtime.type_info_base(type_info_of(tid))
	arr, is_arr := ti.variant.(runtime.Type_Info_Array)
	if !is_arr do return 0, 0
	if arr.count < 2 || arr.count > 4 do return 0, 0
	elem := runtime.type_info_base(arr.elem)
	#partial switch _ in elem.variant {
	case runtime.Type_Info_Float:
		return int(elem.size), arr.count
	}
	return 0, 0
}

@(private)
_bytes_equal :: proc(a, b: rawptr, n: int) -> bool {
	if n <= 0 do return true
	sa := slice.bytes_from_ptr(a, n)
	sb := slice.bytes_from_ptr(b, n)
	return slice.equal(sa, sb)
}

// Suspends multi-edit for a subtree, restoring it at the end of the scope.
//
// Needed where the drawn object's layout stops matching its peers' in a way
// offsets cannot bridge — a union holding a different variant, whose payload
// type differs per object, so the same bytes mean different things.
multi_suspend :: proc() -> []Multi_Peer {
	prev := _multi_peers
	_multi_peers = nil
	return prev
}

multi_resume :: proc(prev: []Multi_Peer) {
	_multi_peers = prev
}

// Rebases the peers onto an array's element storage, so the rows inside can
// multi-edit.
//
// A dynamic array's elements live in a SEPARATE allocation reached through
// `data`, not at a fixed offset from the component base, so the offset
// arithmetic every other field uses cannot address a peer's element. Rebasing
// the peer list onto each peer's own element storage restores it: from there,
// element i is at i*elem_size on every object again.
//
// `array_offset` locates the array FIELD on a peer, the same way any other field
// is located. Fixed arrays are element storage already, so they pass their own
// pointer through.
//
// Returns the count to draw: the SHORTEST length across the selection (Unity's
// rule — see multi_array_common_len), and the previous peers to restore.
// What a rebase replaced, to put back when the array's rows are done.
Multi_Rebase :: struct {
	peers:  []Multi_Peer,
	offset: uintptr,
}

multi_rebase_to_dynamic_array :: proc(
	array_offset: uintptr,
	self_len: int,
	elem_size: int,
	allocator := context.temp_allocator,
) -> (prev: Multi_Rebase, common_len: int) {
	prev = Multi_Rebase{peers = _multi_peers, offset = _multi_base_offset}
	common_len = self_len
	if len(_multi_peers) == 0 do return prev, common_len

	// Offsets inside the array are measured from the ELEMENT STORAGE, so the
	// accumulated component-base offset does not apply any more. Leaving it set
	// would double-count and address past the peer's allocation.
	_multi_base_offset = 0

	rebased := make([dynamic]Multi_Peer, 0, len(_multi_peers), allocator)
	for peer in prev.peers {
		if peer.base == nil do continue
		da := (^runtime.Raw_Dynamic_Array)(rawptr(uintptr(peer.base) + array_offset))
		if da.data == nil || da.len == 0 {
			common_len = 0
			continue
		}
		common_len = min(common_len, da.len)
		// The COMPONENT base is kept, not da.data: the element buffer is
		// reallocated by an undo restore, so it is re-read at use time. See
		// Multi_Peer.
		append(&rebased, Multi_Peer{
			base = peer.base,
			handle = peer.handle,
			scene = peer.scene,
			in_dynamic_array = true,
			array_data_offset = array_offset,
			array_elem_size = elem_size,
		})
	}
	_multi_peers = rebased[:]
	return prev, common_len
}

// Same for a fixed array: its storage IS the field, so only the base moves.
// Lengths are equal by type, so the count is the type's count.
multi_rebase_to_fixed_array :: proc(array_offset: uintptr, allocator := context.temp_allocator) -> Multi_Rebase {
	prev := Multi_Rebase{peers = _multi_peers, offset = _multi_base_offset}
	if len(_multi_peers) == 0 do return prev

	_multi_base_offset = 0
	rebased := make([dynamic]Multi_Peer, 0, len(_multi_peers), allocator)
	for peer in prev.peers {
		if peer.base == nil do continue
		append(&rebased, Multi_Peer{
			base = rawptr(uintptr(peer.base) + array_offset),
			handle = peer.handle,
			scene = peer.scene,
		})
	}
	_multi_peers = rebased[:]
	return prev
}

multi_rebase_end :: proc(prev: Multi_Rebase) {
	_multi_peers = prev.peers
	_multi_base_offset = prev.offset
}

// Whether the selection disagrees about an array's LENGTH. The size row shows a
// dash for this, and the rows past the shortest length are simply not drawn —
// Unity truncates rather than hiding the array.
multi_array_len_mixed :: proc(array_offset: uintptr, self_len: int) -> bool {
	for peer in _multi_peers {
		if peer.base == nil do continue
		da := (^runtime.Raw_Dynamic_Array)(rawptr(uintptr(peer.base) + array_offset))
		if da.len != self_len do return true
	}
	return false
}

// A structural array edit across the selection, as ONE undo step.
//
// Structural array edits apply to the WHOLE selection (Unity's behavior). The
// alternative — editing the active object only — interacts badly with
// shortest-length truncation: the new row sits past some peer's end, so it is
// immediately hidden again and the array looks stuck at the shortest length
// with no way to grow it.
//
// The active object AND every peer are wrapped in one group, so the whole
// action is a single Ctrl-Z. Per-object snapshot/commit pairs alone produce one
// undo entry PER SELECTED OBJECT, which is what "add made 3 undos" looks like.
//
// `self_da` is the active object's array, already located by the caller.
// `peers` is the PRE-REBASE list: this addresses the array FIELD on each peer,
// not element storage.
Multi_Array_Op :: enum {
	Append,
	Remove,
}

multi_array_structural :: proc(
	op: Multi_Array_Op,
	self_da: ^runtime.Raw_Dynamic_Array,
	array_offset: uintptr,
	elem_ti: ^runtime.Type_Info,
	index: int,
	peers: []Multi_Peer,
	label: string,
) {
	// Every object that will actually be touched joins ONE session, so the
	// whole add/remove across the selection is a single undo step.
	targets := make([dynamic]undo.Edit_Target, 0, len(peers) + 1, context.temp_allocator)
	if o, ok := undo.current_owner(); ok && o.kind == .Pooled {
		append(&targets, undo.edit_target_whole(o.handle))
	}
	for peer in peers {
		if peer.base == nil do continue
		da := (^runtime.Raw_Dynamic_Array)(rawptr(uintptr(peer.base) + array_offset))
		// A peer shorter than the index has nothing at that position.
		if op == .Remove && index >= da.len do continue
		append(&targets, undo.edit_target_whole(peer.handle))
	}
	if len(targets) == 0 do return

	sess := undo.edit_session_begin(targets[:], label)

	switch op {
	case .Append:
		append_dynamic_array_element(self_da, elem_ti)
	case .Remove:
		remove_dynamic_array_element(self_da, elem_ti, index)
	}

	for peer in peers {
		if peer.base == nil do continue
		da := (^runtime.Raw_Dynamic_Array)(rawptr(uintptr(peer.base) + array_offset))
		if op == .Remove && index >= da.len do continue
		switch op {
		case .Append:
			append_dynamic_array_element(da, elem_ti)
		case .Remove:
			remove_dynamic_array_element(da, elem_ti, index)
		}
	}

	undo.edit_session_end(&sess)
	mark_inspector_changed()
}
