# Prefabs Specification

> MoonHug Editor uses scenes as prefabs, so "prefab" and "scene" are synonyms in
> this document.

This document defines prefab behaviour independently of any implementation. It
states rules and observable outcomes, not procedures or data structures, so a
different codebase can implement compatible behaviour from it alone.

For how this codebase satisfies it — file layout, records, and the resolve/save
pipeline — see [NestedPrefabs.md](NestedPrefabs.md).

**MUST** is a requirement. **SHOULD** is a requirement with allowed exceptions
where noted. **MAY** is optional.

# 1. Terminology

Unity's prefab vocabulary is used wherever it has a term, so that anyone who
knows Unity's prefab system can read this without translation. Terms marked
*(ours)* name concepts Unity has no published word for.

## Assets and instances

| Term | Meaning |
| --- | --- |
| **Prefab Asset** | The scene file on disk, used as a reusable template. Every scene is a Prefab Asset. |
| **Prefab Instance** | A Prefab Asset embedded in another scene and materialized into live objects. Not a runtime "instantiate" — this is the edit-time embedding. |
| **Prefab Instance Root** | The object a Prefab Instance occupies. The Prefab Asset's own root is absorbed into it, so this object *is* the instance's root — no wrapper object is introduced. |
| **Outermost Prefab Instance Root** | The topmost Prefab Instance Root in a Nesting Chain — the one whose Inspector shows the Overrides dropdown, and the one Apply targets (§4.8). |
| **Nested Prefab** | A Prefab Instance placed inside another Prefab Asset. |
| **Host Scene** *(ours)* | The scene file a Prefab Instance's record is written to. |
| **Prefab Instance Record** *(ours)* | The metadata describing one Prefab Instance in its Host Scene, including all its overrides. A Host Scene holds records only for its Outermost Prefab Instance Roots — deeper instances are described by their own Prefab Asset's file. |

## Variants

| Term | Meaning |
| --- | --- |
| **Prefab Variant** | A Prefab Asset defined as *another Prefab Asset plus overrides and additions*. A Prefab Instance whose root is the scene root. |
| **Base Prefab** | The Prefab Asset a Prefab Variant inherits from. May itself be a Prefab Variant. |

## Content and differences

| Term | Meaning |
| --- | --- |
| **Prefab Content** *(ours)* | Live objects and components that came from a Prefab Asset. Not directly editable — changes to it become overrides. |
| **Authored Content** *(ours)* | Objects and components created directly in the Host Scene, including anything added to a Prefab Instance. |
| **Prefab Override** | A recorded difference between a Prefab Instance and its Prefab Asset. Shortened to **override** where unambiguous. Unity also calls this an *instance override*. |
| **Override Baseline** *(ours)* | The value a Prefab Override is measured against and reverts to: the Prefab Asset's value with its own internal overrides applied, but none from the Host Scene. |

## Nesting

| Term | Meaning |
| --- | --- |
| **Nesting Chain** *(ours)* | A path of Prefab Instances: Host Scene → instance → an instance inside it → … |
| **Nesting Depth** *(ours)* | The number of Prefab Instance hops from the Host Scene to an object. Depth 1 is content of a directly-placed instance. |

# 2. Model

**2.1** A Prefab Asset MUST be usable as a Prefab Instance inside another Prefab
Asset, to arbitrary Nesting Depth. A Prefab Asset MUST NOT contain itself at any
Nesting Depth; an implementation MUST detect such a cycle and refuse rather than
recurse.

**2.2** Prefab Instances are recorded as metadata in the Host Scene, not as
objects in its object tree. A scene file's object tree MUST contain only its own
Authored Content.

**2.3** Editing a Prefab Instance never modifies its Prefab Asset. Every
difference MUST be recorded as a Prefab Override in the Host Scene.

**2.4** A Prefab Asset's own root object is absorbed into the Prefab Instance Root:
embedding a Prefab Instance does NOT introduce a wrapper object. References to
the Prefab Asset's root therefore resolve to the Prefab Instance Root.

**2.5** Changing a Prefab Asset MUST be reflected in every open Prefab Instance of
it, including instances nested inside other Prefab Assets, without reopening the
scene. Overrides on those instances MUST survive the update.

# 3. Override kinds

A Prefab Instance MUST support exactly these five kinds of difference from its
Prefab Asset:

| Kind | Meaning |
| --- | --- |
| **Modified property** | A field on Prefab Content holds a different value. |
| **Added component** | A component the Prefab Instance has that the Prefab Asset does not. |
| **Removed component** | A component the Prefab Asset has that the Prefab Instance does not. |
| **Added object** | An object the Prefab Instance has that the Prefab Asset does not. |
| **Removed object** | An object the Prefab Asset has that the Prefab Instance does not. |

**3.1** Each override MUST identify its subject unambiguously, including when the
subject lies inside a Prefab Asset nested within the instance, and when the same
Prefab Asset appears more than once in one Nesting Chain.

**3.2** Overrides are stored in Prefab Instance Records, which are written to the
Host Scene — never to the Prefab Asset, at any Nesting Depth. Only Outermost
Prefab Instance Roots get a record, so one record must be able to address a
subject any number of levels below it (§3.1).

**3.3** Overrides MUST survive save and reload, and MUST survive re-resolving the
Prefab Instance against a changed Prefab Asset.

# 4. Operations

For each operation: what the user does, what MUST be recorded, and what MUST be
observable afterwards.

## 4.1 Edit a field on Prefab Content

- Records a **modified property** override for that field.
- The override MUST be observable immediately — before any save.
- The field MUST be visually marked as overridden.
- Editing a field that is already overridden updates the existing override; it
  MUST NOT create a second one for the same field.
- Setting a field back to its Override Baseline value MUST leave the override in place.
  Overrides are removed only by an explicit revert (§4.7).

## 4.2 Add a component to Prefab Content

- Records an **added component** override, carrying the component's data.
- The component MUST reappear on reload and after re-resolve.

## 4.3 Remove a component from Prefab Content

- Records a **removed component** override.
- The component MUST NOT reappear on reload or after re-resolve.
- Removing an *added* component (§4.2) MUST retract that addition instead of
  recording a removal — it was never Prefab Content.
- Component order is Prefab Content: reordering components on a Prefab Instance is NOT
  representable and MUST be refused.

## 4.4 Add an object under Prefab Content

- Records an **added object** override, carrying the whole subtree.
- MUST work at any Nesting Depth, including under content belonging to a Prefab
  Asset nested within the instance.
- The object MUST reappear on reload, still parented to the same object.
- Added objects are Authored Content, not Prefab Content: they remain
  overrides on subsequent saves and can themselves be edited freely.

## 4.5 Remove an object from Prefab Content

- Records a **removed object** override.
- The whole subtree goes with it: descendants and their components.
- The object MUST NOT reappear on reload or after re-resolve.
- Removing an *added* object (§4.4) MUST retract that addition instead of
  recording a removal.

## 4.6 Reparent Prefab Content

- NOT representable in this specification. Implementations MUST refuse it
  rather than record a partial or lossy result.

## 4.7 Revert an override

- Removes the override record.
- For a modified property, the field MUST also return to its Override Baseline value.
- For the structural kinds, the Prefab Instance rebuilds from its Prefab Asset, which
  restores or removes the content accordingly.
- Reverting an override that is already gone MUST be a no-op, not an error.
- Reverting one override MUST NOT affect any other, including other overrides on
  the same object.

## 4.8 Apply an override

- Pushes the value into an ancestor Prefab Asset, making it a shared Override
  Baseline rather than a per-instance difference.
- For an override *n* hops deep there are *n + 1* possible destinations: the
  Prefab Asset that owns the field, and each ancestor between it and the
  Host Scene.
- Applying at a destination MUST clear the same override at every level
  shallower than it, or the shallower copy would shadow the applied value (§5.2).
- Applying MUST be atomic: if any part fails, nothing changes.
- Other Prefab Instances of the same Prefab Asset that carry their own override
  for that field MUST keep it; instances without one MUST pick up the new value.

## 4.9 Save

- Writes every override to the Host Scene.
- Save MUST be idempotent: saving, reloading, and saving again MUST produce
  identical bytes.
- Save MUST NOT invent overrides for content the user did not change.
- Overrides whose subject no longer exists in the Prefab Asset MAY be dropped (§7.1).

# 5. Resolution

**5.1 Order.** Materializing a Prefab Instance MUST apply, in this order:
1. the Prefab Asset, with its own overrides already applied (recursively, for
   any Prefab Instance nested inside it),
2. modified-property overrides from the Host Scene,
3. structural overrides (added/removed components and objects).

Structural edits apply last so that added content is not itself patched by
property overrides intended for Prefab Content.

**5.2 Precedence.** Where the same field is overridden at more than one level,
the **shallower** level wins — the Host Scene's override is applied last
and overrides any ancestor's. This is what makes §4.8's clear-above-target rule
necessary.

**5.3 Identity.** Objects materialized from a Prefab Instance MUST receive
identities that are stable across reloads and unique within the Containing
Scene, and MUST be derivable from (Prefab Instance, object in the Prefab Asset).
Two Prefab Instances of one Prefab Asset in the same scene MUST NOT collide.

# 6. Variants

**6.1** A Prefab Variant is a Prefab Asset defined as *a Base Prefab plus
overrides and additions*. Structurally it is a Prefab Instance of its Base Prefab
whose Prefab Instance Root is the scene root.

**6.2** The Base Prefab's root IS the Prefab Variant's root — no wrapper object,
consistent with §2.4.

**6.3** A Prefab Variant MUST be usable anywhere a plain Prefab Asset is: placed
as a Prefab Instance, nested inside another Prefab Asset, and used as the Base
Prefab of a further Prefab Variant.

**6.4** A Prefab Variant's own overrides are part of what it defines. When it is
used as a Prefab Instance elsewhere, only the Host Scene's overrides on it
are editable there; its internal overrides are not revertable from outside it.

# 7. Divergences from Unity

Stated because implementers targeting Unity compatibility need them.

**7.1 Stale overrides are dropped.** Unity preserves overrides whose subject has
disappeared, so restoring the subject recovers them. This specification permits
dropping them at save. Trade-off: cleaner files, no recovery.

**7.2 Root overrides are not special.** Unity treats a root object's name and
transform as "default overrides", hides them from the overrides list, and
excludes them from bulk apply/revert. This specification treats them like any
other override.

# 8. Conformance

An implementation conforms if:

**8.1** Every operation in §4 produces the stated observable result after save
and reload.

**8.2** Every operation in §4 is undoable and redoable, restoring both the
override record and the affected values.

**8.3** Save is idempotent (§4.9) and does not invent overrides.

**8.4** §4 operations behave identically at Nesting Depth 1 and at Nesting Depth
*n*, except where a rule names Nesting Depth explicitly.

**8.5** Two Prefab Instances of the same Prefab Asset in one scene can be
overridden independently, with no leakage between them.

**8.6** Changing a Prefab Asset updates open Prefab Instances while preserving
their overrides (§2.5).
