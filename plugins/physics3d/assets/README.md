# Physics (3D)

3D physics simulation built on box3d, with Unity-style authoring: add plain
data components to objects, press Play, and the package simulates them on the
engine's fixed tick. The editor never simulates — bodies exist only while the
app runs.

## Components (Add Component → Physics)

- **Rigidbody** — makes the object dynamic. `use_gravity` toggles gravity,
  `is_kinematic` makes it animation/code-driven (it pushes dynamic bodies but
  is never pushed), freeze flags lock position/rotation per axis.
- **BoxCollider / SphereCollider / CapsuleCollider** — collision shapes with
  a local `center` offset. Transform scale affects the shape size.

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

Every collider has two layer fields, bits of the engine's `"physics"` layer domain ([Layers](../../engine/docs/Layers.md)):

- `layers` is the layers the collider is on. Several bits are allowed. A new collider is on layer 0
- `mask` is the layers the collider collides with. A new collider collides with every layer

Two colliders collide when `(a.layers & b.mask) != 0 && (b.layers & a.mask) != 0`, box3d's own rule. The same test decides whether a trigger reports an overlap. The fields become the shape filter's `categoryBits` and `maskBits` when the shape is created, and each physics step writes a changed `layers` or `mask` into the live shape, so an edit during play or from a script applies on the next step.

The 32 layer names are the names of the project's Physics Layers asset, the one the `physics_layers` field of Edit ▸ Project Settings… ▸ Layers names (the essentials plugin's `assets/physics/DefaultPhysicsLayers.asset` until a project picks its own). To name the layers, create an asset with Assets ▸ Create ▸ Physics Layers, name its layers in the inspector, save it and pick it in that field. The 2D and the 3D colliders share that list. Layer 0 is "Default", an empty name is an unused layer, and the inspector's layer picker lists the named ones. The domain is separate from the render layers: an object's render layer says nothing about what it collides with.

## Going beyond the components

`body_of(handle)` returns the live box3d body, so forces, joints, raycasts
and anything else box3d offers can be used directly from game code.

## Current limitations

- Moving or rescaling a child collider after creation doesn't re-bake its shape, and runtime component field edits other than `layers` and `mask` don't re-sync (use `body_of`).
- No mesh colliders or physics material assets yet.
