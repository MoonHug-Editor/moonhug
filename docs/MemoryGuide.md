# Memory Guide (Odin)

Odin language uses manual memory management and doesn't have garbage collector.  
You allocate and free manually via provided API.

This guide covers some concepts for better leak-free, crash-free code.  
Ordered from simple to more complex.

## Allocation/Deallocation tools and concepts

---
### Owner, reference
When memory is allocated its address is stored in some Owner (variable, struct).  

> Rule: There can be only one owner for same backing memory

> Rule: When removing owner its owned memory also should be cleaned up

> Rule: Ref becomes dangling pointer after backing memory gets freed

---
### stack vs heap

Stack doesn't require manual freeing so prefer it over heap when possible.

```odin
x: [dynamic]int // created on heap
y: [dynamic;64]int // created on stack
```
> Use the **stack** Luke

---
### slice
slice is a stack variable, look into heap memory
```odin
a:[dynamic]int
defer delete(a)

append(&a, 11)
append(&a, 22)
append(&a, 33)

a_slice := a[0:2] // {11, 22} created on stack, no need to deallocate

append(&a, 44)      // may reallocate `a`— a_slice.data now potentially dangling
_ = a_slice[0]      // unsafe
```

---
### defer

- `defer` operations are guaranteed to execute at the end of scope in opposite order of declaration (FILO/LIFO)
> `defer` cleanup immediately after **successful allocation**.

---
### [new](http://pkg.odin-lang.org/base/builtin/#new) / [free](http://pkg.odin-lang.org/base/builtin/#free) - one element

```odin
a :^T= new(T)        // allocates 1 T
defer free(a)        // frees 1 T
```
> Mirror `new` with `free`.  
> ＼(*´▽｀*)／ Everyone likes **new and free**

---
### [make](https://pkg.odin-lang.org/base/builtin/#make) / [delete](https://pkg.odin-lang.org/base/builtin/#delete) - array of elements

```odin
buf  := make([]byte, 256)         // slice — fixed-length backing array
defer delete(buf)

arr  := make([dynamic]int)        // dynamic array — growable
defer delete(arr)

m    := make(map[string]int)      // map
defer delete(m)
```

> Mirror `make` with `delete`.  
> Make multiple, delete multiple

## Special case examples
### proc returns allocated data

```odin
s := strings.clone("hello")    // allocates string
defer delete(s)                // frees the backing memory
```

### proc returns allocated data and error
```odin
data, err := os.read_entire_file(path, context.allocator) // allocates data on success
if err != nil do return // assumes data wasn't allocated due to error
defer delete(data)      // freed no matter how we exit from here
```

---

### dynamic array of values on heap
```odin
s: [dynamic]string

defer(delete(s)) // leaks string values

defer{ // correct — free each owned string first
  for str in s do delete(str)
  delete(s)
}

append(&s, strings.clone("hello"))
append(&s, strings.clone("world"))
```

---
### struct owns heap value
```odin
S :: struct {
 a:int,
 n:string,
}

cleanup_S :: proc(s: ^S) {
 delete(s.n)
 free(s)
}

s := new(S)
cleanup_S(s)
```

> Rule: If a type owns heap data, it needs destroy proc

---

### JSON cleanup

`json.parse_value` allocates a `json.Value` tree. Destroy it with `json.destroy_value`:

```odin
val, err := json.parse_value(p)
if err != nil do return err
defer json.destroy_value(val)   // frees the parsed JSON tree
```
---
# [Allocators](https://odin-lang.org/docs/overview/#allocators)

## Context Allocators
Every Odin procedure has an implicit `context` value threaded through it.  
The `context` carries two allocators:

### 1. context.allocator
```odin
context.allocator       // manual free allocator
```
> Using context.allocator is like saying: I'm responsible for freeing this by defer on next line, or later by other technique

### 2. context.temp_allocator
by default is assigned to scratch allocator (a growing arena based allocator)
```odin
context.temp_allocator  // manual bulk-free at a known boundary (e.g. end of frame)
```
> Using temp_allocator is like saying: I don't want to bother with freeing now, I'll free_all later (at end of frame, etc.)

### Usage
`context.allocator` is used by default in built-in procedures (`new`, `make`, `strings.clone`, `append`, etc.).  
You can override it by:
- passing an allocator explicitly
- reassigning `context.allocator` for the duration of a scope.

```odin
ptr := new(int)  // uses context.allocator
ptr_on_temp := new(int, context.temp_allocator)  // uses override

temp_str := strings.clone(s) // uses context.allocator
temp_str_on_temp := strings.clone(s, context.temp_allocator) // uses override
```

### Temp allocator data escaping the frame

```odin
// WRONG: clones into temp_allocator, then stores the pointer long-term
t.name = strings.clone(name, context.temp_allocator)
// temp is cleared at end of frame; t.name is now a dangling pointer

// CORRECT:
t.name = strings.clone(name)  // uses context.allocator; persists until delete(t.name)
```


---

## [Tracking Allocator](https://odin-lang.org/docs/overview/#tracking-allocator)

Odin's test framework wraps `context.allocator` in a `mem.Tracking_Allocator` that records every allocation and free. At the end of a test it reports:

- **leak** — an allocation that was never freed
  - Warning: global memory allocations that match app's full lifetime will also be reported as leak, even though everything will be sweep'ed by OS on exiting program.<br>So it's good practice to cleanup explicitly to not cover other obvious leaks.
- **bad free** — a free of an address that wasn't allocated by this allocator (wrong allocator, double-free, or already freed)

```odin
import "core:mem"
import "core:fmt"

main :: proc() {
	when ODIN_DEBUG {
        track: mem.Tracking_Allocator
        mem.tracking_allocator_init(&track, context.allocator)
        context.allocator = mem.tracking_allocator(&track)

        defer {
            for _, entry in track.allocation_map {
                fmt.eprintf("leak %v bytes @ %v\n", entry.size, entry.location)
            }
            for entry in track.bad_free_array {
                fmt.eprintf("bad free @ %v\n", entry.location)
            }
            mem.tracking_allocator_destroy(&track)
        }
    }

    run_program()
}
```


## Allocator Consistency — Avoiding Bad Frees

A **bad free** happens when you call `free` (or `delete`) on a pointer using a different allocator than the one that allocated it.

### Allocator new/free mismatch
```odin
// WRONG: json unmarshal allocates with runtime.default_allocator(), but transform_destroy
// will free the name with context.allocator (the tracking allocator in tests)
json.unmarshal(data, &s, allocator = runtime.default_allocator())
defer free(s)

// CORRECT: use context.allocator throughout so alloc and free match
json.unmarshal(data, &s)
defer free(s)

```

> **Rule:** free with the same allocator that allocated. Freeing a `temp_allocator` allocation with `context.allocator` (or vice versa) is a bad free.
---

## Shallow Copy

- A struct assignment copies fields by value.  
- Dynamic arrays, slices, maps, and strings contain a header (pointer + length + capacity).  
Assigning them copies the header, not the underlying data. Both the source and destination now point at the same backing memory — called a shallow copy.

### Dangling pointer and double free example
```odin
a := make([dynamic]int)
append(&a, 1, 2, 3)

b := a          // shallow copy: b.data == a.data
append(&b, 4)   // if b reallocates: a.data becomes a dangling pointer
                // if b does NOT reallocate: delete(a) + delete(b) = double-free

delete(a)  // <-- can be dangling
delete(b)  // <-- double free
```

### Transfer ownership

Transfer responsibility for freeing to a new owner by zeroing the source so only one variable is responsible for freeing it:
```odin
a := make([dynamic]int)
append(&a, 1, 2, 3)

b: [dynamic]int
b = a       // b now points at the same backing memory as a
a = {}      // zero the source — b is now the sole owner
            // delete(a) is a no-op, calling or not calling it does nothing
delete(b)   // only one delete, no double-free
```

## Deep copy
When you need two independent owners:

```odin
a := make([dynamic]int) // allocate memory a
append(&a, 1, 2, 3)

b := make([dynamic]int, len(a)) // allocate same len memory at different address
copy(b[:], a[:])        // copy from a slice to b slice

delete(a)               // delete memory at a
delete(b)               // delete memory at b, no double-free
```

---

## Quick Reference

| Situation                   | What to do                                                                                     |
|-----------------------------|------------------------------------------------------------------------------------------------|
| Allocate a single value     | `ptr := new(T)` → `defer free(ptr)`                                                            |
| Allocate a slice            | `s := make([]T, n)` → `defer delete(s)`                                                        |
| Allocate a dynamic array    | `a := make([dynamic]T)` → `defer delete(a)`                                                    |
| Clone a string              | `s := strings.clone(src)` → `defer delete(s)`                                                  |
| Short-lived scratch         | use `context.temp_allocator` → `free_all(context.temp_allocator)` at frame end                 |
| Struct owns a dynamic array | implement a `destroy_Foo` proc that deletes all fields                                         |
| Nested owned data           | recurse in destroy: free children before deleting the parent array                             |
| JSON-allocated tree         | `defer json.destroy_value(val)` after `json.parse_value`                                       |
| Verify no leaks             | wrap allocator in `mem.Tracking_Allocator` or run `odin test` (tracking is enabled by default) |

## Links
- [package mem](https://github.com/odin-lang/Odin/tree/master/core/mem) — more uses of allocators and allocation-related procedures.
- [Ginger Bill’s Memory Allocation Strategy](https://www.gingerbill.org/series/memory-allocation-strategies/) series — more information regarding memory allocation strategies in general.
