# Inspector Property

> Implemented: `editor/inspector/property.odin`. Consumers: the
> TimelineAnimator's per-track binding rows (`property_row`) and the MCP
> `get_property` / `set_property` tools (`property_get_json` /
> `property_set_json`, docs/McpBridge.md).

An ADDRESSED FIELD: a field on an object, resolved from the owner and a dotted
path, carrying everything a write or a row needs — the value, the undo owner,
the prefab instance an override lands on, and the field the override names.

## The problem

A field's address is five separate facts. The generic field loop has all five
in scope as it walks, so it never names them together:

| Fact | In the generic loop |
|---|---|
| the value | `(ptr, tid)` passed down the walk |
| the object that owns it | `undo.current_owner()` — an ambient stack |
| where an override lands | `inspector_get_nested_host()` + `nested_local_id` — ambient |
| what an override names | `_field_edit_path` — ambient, concatenated on the way down |
| the field's picker tags | `current_field_ref_target` and three siblings — ambient |

Paths are EMITTED by that walk, never RESOLVED: nothing turns `"meta.color.g"`
back into a pointer. `_json_get_path` / `_json_set_path`
(engine/nested_scene.odin) resolve dotted paths in JSON only, for applying and
reverting overrides. So a field can be addressed only while the loop is
drawing it, and anything else has to reproduce the five facts by hand.

Two callers need addressing without the walk:

- **A proxy row.** A panel drawing another component's field — the animator
  showing each track's `target`. It gets the field's name from a registry
  (`Track_Desc.binding_field`) and has to find the pointer, the type, the
  picker tags, the undo owner and the prefab context of THAT component. The
  first version did this by hand and got the prefab context wrong.
- **A property write over the wire.** An MCP `set_property(object, path,
  value)` gets a path as text and has to reach the field with undo and the
  override recorded exactly as if the inspector had done it. It draws nothing.

The resolver is the shared part. Drawing is a thin wrapper on it.

## The API

```odin
// An object to address fields on. Captures the undo owner and the prefab
// instance an override belongs to, so a caller cannot forget or inherit them.
inspect_comp      :: proc(comp: engine.Handle) -> (Property, bool)
inspect_transform :: proc(tH: engine.Transform_Handle) -> (Property, bool)

// Narrow to a field. Chainable: the result addresses an object too.
property :: proc(p: Property, path: string) -> (Property, Resolve_Error)

// Draw it as one row: marker, transaction, override record, context menu.
property_row :: proc(p: Property, label: string, drawer = nil, draw_label = "") -> (finished: bool)

// Or write it with no row: one undo step, override recorded. The wire path.
// A refused write says why: bad shape, or a reference the field's ref: / has:
// tags do not admit — the rule the picker enforces by what it offers.
property_get_json :: proc(p: Property) -> []byte
property_set_json :: proc(p: Property, json_bytes: []byte, label: string) -> (ok: bool, why: string)
```

The proxy row:

```odin
owned, _ := engine.transform_get_comp_key(track_node, desc.track_key)
p, _ := inspector.inspect_comp(owned.handle)
b, err := inspector.property(p, desc.binding_field)
if err != .None do fmt.panicf(...)   // the name is a literal the kind registered
inspector.property_row(b, "Track Binding", draw_label = track_name)
```

## The value

```odin
Property :: struct {
    ptr: rawptr,
    tid: typeid,
    tag: reflect.Struct_Tag, // ref: / has: / pick: / ext:

    owner:  undo.Inspector_Owner, // the undo target
    base:   rawptr,
    offset: uintptr,              // ptr - base

    nested_host: engine.Transform_Handle, // which prefab instance an override lands on
    nested_lid:  engine.Local_ID,

    record: Override_Field, // what an override NAMES — see "Two addresses"
}
```

A VALUE, built and discarded within a frame. Nothing registers it and nothing
outlives the draw, so a pool slot moving is no problem — the next frame
resolves again from the handle. The resolver has no imgui in it: only
`property_row` draws.

## Two addresses

A path addresses the value. A prefab override names something that may be
coarser.

```
property(p, "layers[0].states[2].speed")

  value        &speed, f32
  record.path  "layers"
  record.ptr   &a.layers, [dynamic]Animator_Layer
```

**The override path stops at the first array index.** An override is the whole
array, atomically, never an element (`docs/PrefabsSpec.md`,
`test_diff_overrides_array_atomic`). Revert on that speed row restores all of
`layers`, and the marker lights on every row inside it. A fixed array is an
array too: `position[1]` records against `position`.

Undo reaches the same boundary by its own route. `edit_target_pooled` resolves
a field to an offset from the component base, and an element in heap array
storage is not inside the component, so `_ptr_within` fails and the step
records the whole component. Two mechanisms that never consult each other
agree, which is the sign the rule is real.

## Resolution

One segment at a time from `base` and its typeid:

- `name` — `reflect.struct_field_by_name`; take the offset, type and tag.
- `[i]` — index a fixed array or a `Raw_Dynamic_Array`, bounds checked. From
  here on `record` is frozen at the array.
- a pointer field is followed before the next segment.

Failure is a `Resolve_Error`, never a panic: `No_Such_Field`,
`Index_Out_Of_Range`, `Not_Indexable`, `Not_A_Struct`, `Bad_Path`. The wire
consumer reports it to the agent. A caller holding a source literal, like the
animator with a registered `binding_field`, panics on its own side — the miss
is that kind's bug.

## What it changes, and what it does not

Nothing about undo, override recording or the drawers. Those were already
correct and shared. This is addressing:

- `property_row` pushes the property's owner, prefab context and picker tags,
  clears the multi-edit peers, draws through `custom_field_row`, and puts all
  of it back. A row for another component leaves the inspector's own context
  untouched.
- `inspect_comp` calls `nested_context_for_comp` itself, so the prefab
  context cannot be forgotten or inherited from the wrong object.
- The sequencer's `Track_Desc` registers only `binding_field: string`. There
  is no struct passing a resolved field across the package boundary — the
  animator resolves it on the live track component.

Rows that already hold a pointer — the animator's own state rows, the
Animation tree — keep `custom_field_row`. They iterate live arrays and have
`&st.speed` in hand; formatting a path to resolve it back to the same pointer
would gain nothing. `custom_field_row` is the row primitive, `property_row` is
the addressed form of it.

The generic loop keeps its own walk. It emits paths, it never needs to resolve
one, and rewriting it over `Property` would replace one walker with another.

## Deliberately not

- **No deferred apply.** Writes go straight to the component and the row's
  before/after snapshot gives correct undo. A buffered copy applied on commit
  would be a second source of truth for a value the scene view, the sequencer
  window and the preview all read continuously.
- **No typed accessors.** `(ptr, tid)` plus the drawer registry is already the
  type dispatch, and it covers types a fixed accessor list would not.
- **No overrides by pointer.** The path stays a string because that is what
  the serialized form uses, and a pointer cannot name a field of an object
  that is not loaded.
- **No peers on the property.** A proxy has none of the selection's peers, and
  the wire consumer names one object. Multi-edit stays in the generic loop
  until a consumer needs it here.

## TODO

1. **Serialized name vs field name.** Paths use Odin field names, as does the
   override path the generic loop builds. A field carrying `json:"other"`
   would record an override against a key the file does not have. No
   component renames a field today, so this is latent — resolution is where it
   gets fixed.
2. **Union descent.** A path cannot enter a union's active variant. Not needed
   by the first two consumers.
