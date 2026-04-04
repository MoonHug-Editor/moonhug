# Reference Handles

## Core concepts

```
Handle       — runtime-only slot reference (index + generation + type_key); is never serialized
Pool         — fixed-size generational array that owns objects of one type
PPtr         — persistent pointer that survives serialization (local_id + guid)
Ref_Local    — same-file reference: local_id + Handle
Ref          — cross-asset or same-file reference: PPtr + Handle; for ex. Transform.parent
Owned        — owner must destroy it when dies; alias for Ref_Local; for ex. Transform.components
```

## Reference types

```odin
Handle :: struct {
    index:      u32,
    generation: u16,
    type_key:   TypeKey,
}

PPtr :: struct {
    local_id: Local_ID,
    guid:     Asset_GUID,   // zero = same file (local)
}

Ref_Local :: struct {          // local reference
    local_id: Local_ID,
    handle:   Handle `json:"-"`,
}

Ref :: struct {      // cross-asset reference
    pptr:   PPtr,
    handle: Handle `json:"-"`,
}

Owned :: distinct Ref_Local    // component slot on a Transform
```

- `Handle` is runtime only — never written to disk (`json:"-"`).
- `Local_ID` is file-scoped; every transform and component in a scene gets one.
- `Asset_GUID` is a UUID that identifies the asset file. Zero with Local_ID means the reference is local to the current file.
- `TypeKey` inside a `Handle` routes pool dispatch through `world_pool_*` procs.

## Pool

`Pool($T)` is a fixed-size generational slot array (capacity `MAX = 1024`).

```odin
Pool :: struct($T: typeid) {
    slots:     [MAX]struct { generation: u16, alive: bool, data: T },
    freelist:  [MAX]u32,
    free_head: int,
    count:     int,
}
```

### Lifetime

```
pool_init()    → fills freelist, sets all generations to 1
pool_create()  → pops freelist, marks slot alive, returns Handle + ^T
pool_destroy() → marks slot dead, bumps generation, pushes back to freelist
pool_get()     → returns ^T if handle is valid, nil otherwise
pool_valid()   → alive && generation matches
```

Generation starts at 1. Destroying a slot increments its generation, so any existing `Handle` pointing to that slot becomes stale and `pool_valid` returns false.

## World pool dispatch by TypeKey

The `World` holds a `pool_table` keyed by `TypeKey`. Each entry is a `Pool_Entry` with function pointers for `get`, `valid`, `create`, `destroy`, and `collect`.

```odin
world_pool_get     :: proc(w: ^World, handle: Handle) -> rawptr
world_pool_valid   :: proc(w: ^World, handle: Handle) -> bool
world_pool_create  :: proc(w: ^World, type_key: TypeKey) -> (Handle, rawptr)
world_pool_destroy :: proc(w: ^World, handle: Handle)
world_pool_collect :: proc(w: ^World, handle: Handle, sf: ^SceneFile)
```

`world_pool_create` stamps the `type_key` onto the returned `Handle` so subsequent dispatch calls route to the correct pool.

## TypeKey

`TypeKey` is a generated `enum u16` with one value per registered type. `INVALID_TYPE_KEY = max(u16)`.
Used for runtime optimization over typeid, should not be serialized.

```odin
TypeKey :: enum u16 {
    Script         = 7,
    SpriteRenderer = 8,
    // ...
}
```

Each registered type also gets a stable `Asset_GUID` constant (e.g. `SpriteRenderer__Guid`) used for cross-asset serialization.

## Serialization behaviour

| Field | Serialized | Notes |
|---|---|---|
| `Handle` | No (`json:"-"`) | Resolved at load time |
| `Local_ID` | Yes | File-scoped stable identity |
| `Asset_GUID` | Yes | Cross-asset stable identity |
| `PPtr` | Yes | Composed of the above two |

On save, handles are stripped. On load, `local_id` values are used to rebuild handles by scanning the flat arrays in `SceneFile`.
