# Physics (3D)

3D physics simulation built on box3d, with Unity-style authoring: add plain
data components to objects, press Play, and the package simulates them on the
engine's fixed tick. The editor never simulates — bodies exist only while the
app runs.

## Components (Add Component → Physics)

- **Rigidbody** — makes the object dynamic. `mass` is the body's mass in
  kilograms (default 1), and the colliders' `density` only spreads it: the
  center of mass and the inertia. `use_gravity` toggles gravity,
  `is_kinematic` makes it animation/code-driven (it pushes dynamic bodies but
  is never pushed), freeze flags lock position/rotation per axis.
- **BoxCollider / SphereCollider / CapsuleCollider** — collision shapes with
  a local `center` offset. Transform scale affects the shape size. `material`
  names a Physics Material ("Physics materials").
- **MeshCollider** — a mesh's own shape. `mesh` names a model or one of its parts, and left empty it is the MeshFilter's mesh on the same object. `convex` collides as the convex hull of the vertices, reduced to the 44 the box3d hull holds (`HULL_MAX_VERTICES`), the only form a Rigidbody can carry. Not convex, the triangles collide as they are, on a static body only: a non-convex MeshCollider under a Rigidbody builds nothing and says so in the log. Transform scale applies per axis, mirrored scale included. The gizmo draws the hull's edges when convex and the mesh's triangles otherwise.

## How bodies form

- A collider **without** a Rigidbody anywhere above it is a **static** body.
- A collider **below** a Rigidbody attaches to that body as one of its shapes
  (compound bodies), with its relative placement baked when the body is
  created.
- Marking a collider a **trigger** makes it a sensor: it reports overlaps but
  doesn't collide.

## Reacting to collisions

Contacts are polled, not called back. Each physics step buffers begin/end
contact and sensor events. Read them from a `@(fixed_update)` proc ordered
after the physics step (order > 1000):

- `contact_begin_events()` / `contact_end_events()`
- `sensor_begin_events()` / `sensor_end_events()`

Each event pairs the two transforms involved (for sensors: the sensor first,
the visitor second).

## Collision layers

The 3D colliders have collision layers of their own, separate from the render layers and from the other physics plugin's (`layers.odin`, layer domain `"physics3d"`). One asset of this plugin holds them: a Physics 3D Layers asset (`Physics3D_Layers`, Assets ▸ Create ▸ Physics 3D Layers), picked in the `layers` field of the Physics 3D project settings (Edit ▸ Project Settings… ▸ Physics 3D). It has two fields:

- `names`: the names of the 32 layers. An empty name is an unused layer
- `rows`: which pairs of layers collide. Bit j of row i set means a collider on layer i and a collider on layer j collide

A new asset, and a project whose setting is unset, name layer 0 "Default" and let every pair collide. The inspector draws `rows` as a triangle of checkboxes labelled with the asset's own `names` ([Layers](../../engine/docs/Layers.md) "Collision matrix inspector"). An edit of the asset the settings name reaches the layer picker and the physics step before it is saved, and so does a change of its file on disk or a switch to another asset.

Every collider has `layers`, the layers it is on. Several bits are allowed, and a new collider is on layer 0. Colliders and rigidbodies change their own share with `layer_overrides` (`Physics3D_Layer_Overrides`, drawn inline):

- `include` adds layers the matrix leaves out
- `exclude` removes layers whatever the matrix says

A collider's own overrides add to those of the rigidbody it attaches to, so an override on the body applies to every collider attached to it. The filter mask is the matrix's rows for the collider's `layers`, plus both includes, minus both excludes (`collision_mask`). Two colliders collide when `(a.layers & b.mask) != 0 && (b.layers & a.mask) != 0`, box3d's own rule, so an exclude on either side wins. The same test decides whether a trigger reports an overlap. The layers and the mask become the shape filter's `categoryBits` and `maskBits` when the shape is created, and each physics step writes a changed value into the live shape, so an edit of the matrix, the layers or the overrides applies on the next step.

## Physics materials

A Physics Material asset (`PhysicsMaterial`, Assets ▸ Create ▸ Physics Material) says how a surface slides and bounces: `friction`, `bounciness` (0 to 1), and how each combines with the other collider's when two touch: `friction_combine` and `bounce_combine`, each Average, Minimum, Multiply or Maximum. When the two colliders' modes differ, the higher-ranked one wins: Maximum above Multiply above Minimum above Average.

- A collider names its material in `material`, with a foldout that edits the asset in place.
- A collider with no material uses the Physics 3D settings' Default Material (Edit ▸ Project Settings… ▸ Physics 3D), and with that unset the defaults of a new asset: friction 0.6, bounciness 0, both combines Average.
- An edit of a material, in the inspector or on disk, reaches the colliders that use it on the next physics step, also while the game runs.
- Box3D keeps one friction coefficient per shape, for sliding and resting alike.

## Going beyond the components

`body_of(handle)` returns the live box3d body, so forces, joints, raycasts
and anything else box3d offers can be used directly from game code.

## Current limitations

- Moving or rescaling a child collider after creation doesn't re-bake its shape, and runtime component field edits other than `layers` and `layer_overrides` don't re-sync (use `body_of`).
- No mesh colliders yet.
