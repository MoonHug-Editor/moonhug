## Concepts
- World          — owner of runtime pools of all possible entities and components
- Pool(T)        — handle-based storage for one entity type


- SceneManager   — all scenes holder
- Scene          — scene id + other info, root transform reference
- SceneFile      — serialized Transform tree, plain structs + local_ids
- scene_files    — map loaded into memory to be used for scene loading and transform tree instantiation

- Transform      — spatial component, tree relationships, owns array of components

- Component      — referencable type in living on Transform
- Asset          — referencable PPtr non-scene file (Mesh, Material etc.), shared


- Owned          — localId + runtime handle + typeid
- Ref            — PPtr + runtime Handle + typeid
- PPtr           — stable file+object reference (guid + local_id)
- Handle         — runtime reference (index + generation)

-----

Rules:
- Transform and components can be referenced across file via local_id
  - file should manage set of local_ids
- When component is attached to transform it gets valid local_id
- When transform is created in scene it gets valid local_id
- When transform is added to a different scene: itself, its components and children get local_id remap

-----
Odin zero initialization ensures allocated data is empty.
This simplifies deserialization step as it allocates into empty fields.

Default values for components:

- Prefabs(or serialized data, etc.) are source of defaults(to not fight with deserialization)
  - deserialization should happen on zeroed object.

TODO: Consider merge of type defaults + prefab defaults into 1 serialized structure so that deserialization happens once on zero initialized object
