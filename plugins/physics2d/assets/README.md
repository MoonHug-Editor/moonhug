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
  but is never pushed) or Static. `gravity_scale` tunes gravity per body,
  `fixed_rotation` locks rotation.
- **BoxCollider2D / CircleCollider2D / CapsuleCollider2D** — collision shapes
  with a local `offset`. Transform scale affects the shape size.

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

## Going beyond the components

`body_of(handle)` returns the live box2d body, so forces, joints, raycasts
and anything else box2d offers can be used directly from game code.

## Current limitations

- Moving or rescaling a child collider after creation doesn't re-bake its
  shape, and runtime component field edits don't re-sync (use `body_of`).
- No layer collision matrix, effectors, polygon/edge colliders, or physics
  material assets yet.
