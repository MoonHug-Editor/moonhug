# Physics2D

2D physics simulation built on box2d, with Unity-style authoring: add plain
data components to objects, press Play, and the package simulates them on the
engine's fixed tick. The editor never simulates — bodies exist only while the
app runs.

Units: 1 world unit = 1 meter (= 100 px on screen). Bodies move in the XY
plane and rotate around Z.

## Components (Add Component → Physics2D)

- **Rigidbody2D** — makes the object simulated. `body_type` picks Dynamic
  (fully simulated), Kinematic (animation/code-driven, pushes dynamic bodies
  but is never pushed) or Static. `mass` is the body's mass in kilograms
  (default 1), and the colliders' `density` only spreads it, unless
  `use_auto_mass` is on, when the density decides the mass. `gravity_scale` tunes gravity per body,
  `fixed_rotation` locks rotation.
- **BoxCollider2D / CircleCollider2D / CapsuleCollider2D** — collision shapes
  with a local `offset`. Transform scale affects the shape size. `material`
  names a Physics Material 2D, and a Rigidbody2D's `material` is the default
  of its colliders ("Physics materials").
- **PolygonCollider2D** — any simple polygon as a solid shape: a closed path of `points` around `offset`, five points on a circle to start. The path is split into convex pieces of at most 8 points, one box2d polygon each on the body, so a concave outline collides as drawn. A path that is not a simple polygon (crossing edges, all points on a line) builds nothing and says so in the log until it is edited. Transform scale applies per axis.
- **EdgeCollider2D** — an open line of `points` around `offset`, for ground outlines: a box2d chain, smooth across its corners and one-sided: the solid side is to the right of the path's direction, so a floor's points run from right to left, and a body behind the line passes through. Each end continues straight so a body sliding off is not caught on it. It has no inside and no mass, and it cannot be a trigger.

## How bodies form

- A collider **without** a Rigidbody2D anywhere above it is a **static** body.
- A collider **below** a Rigidbody2D attaches to that body as one of its
  shapes (compound bodies), with its relative placement baked when the body
  is created.
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

The 2D colliders have collision layers of their own, separate from the render layers and from the other physics plugin's (`layers.odin`, layer domain `"physics2d"`). One asset of this plugin holds them: a Physics 2D Layers asset (`Physics2D_Layers`, Assets ▸ Create ▸ Physics 2D Layers), picked in the `layers` field of the Physics 2D project settings (Edit ▸ Project Settings… ▸ Physics 2D). It has two fields:

- `names`: the names of the 32 layers. An empty name is an unused layer
- `rows`: which pairs of layers collide. Bit j of row i set means a collider on layer i and a collider on layer j collide

A new asset, and a project whose setting is unset, name layer 0 "Default" and let every pair collide. The inspector draws `rows` as a triangle of checkboxes labelled with the asset's own `names` ([Layers](../../engine/docs/Layers.md) "Collision matrix inspector"). An edit of the asset the settings name reaches the layer picker and the physics step before it is saved, and so does a change of its file on disk or a switch to another asset.

Every collider has `layers`, the layers it is on. Several bits are allowed, and a new collider is on layer 0. Colliders and rigidbodies change their own share with `layer_overrides` (`Physics2D_Layer_Overrides`, drawn inline):

- `include` adds layers the matrix leaves out
- `exclude` removes layers whatever the matrix says

A collider's own overrides add to those of the rigidbody it attaches to, so an override on the body applies to every collider attached to it. The filter mask is the matrix's rows for the collider's `layers`, plus both includes, minus both excludes (`collision_mask`). Two colliders collide when `(a.layers & b.mask) != 0 && (b.layers & a.mask) != 0`, box2d's own rule, so an exclude on either side wins. The same test decides whether a trigger reports an overlap. The layers and the mask become the shape filter's `categoryBits` and `maskBits` when the shape is created, and each physics step writes a changed value into the live shape, so an edit of the matrix, the layers or the overrides applies on the next step.

## Physics materials

A Physics Material 2D asset (`PhysicsMaterial2D`, Assets ▸ Create ▸ Physics Material 2D) says how a surface slides and bounces: `friction`, `bounciness` (0 to 1), and how each combines with the other collider's when two touch: `friction_combine` and `bounce_combine`, each Average, Mean (the geometric mean, `sqrt(a * b)`), Multiply, Minimum or Maximum. When the two colliders' modes differ, the higher-ranked one wins: Maximum above Minimum above Multiply above Mean above Average.

- A collider names its material in `material`, with a foldout that edits the asset in place. A collider with none takes the material of the Rigidbody2D it attaches to, so one body can set the material of all its colliders.
- A collider and Rigidbody2D with no material use the Physics 2D settings' Default Material (Edit ▸ Project Settings… ▸ Physics 2D), and with that unset the defaults of a new asset: friction 0.4, bounciness 0, friction combined by Mean and bounciness by Maximum, which is how Box2D mixes them on its own.
- An edit of a material, in the inspector or on disk, reaches the colliders that use it on the next physics step, also while the game runs.
- Box2D keeps one friction coefficient per shape, for sliding and resting alike.

## Going beyond the components

`body_of(handle)` returns the live box2d body, so forces, joints, raycasts
and anything else box2d offers can be used directly from game code.

## Current limitations

- Moving or rescaling a child collider after creation doesn't re-bake its shape, and runtime component field edits other than `layers` and `layer_overrides` don't re-sync (use `body_of`).
- No effectors or polygon/edge colliders yet.
