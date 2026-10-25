---
title: "Data"
description: "The engine's data model: the world, pools and handles, components, and how things reference each other"
weight: 10
path: engine/data/_index.md
---

Everything the engine runs is data in pools, reached by handles and referenced by stable ids. These pages describe that model from the vocabulary up.

- [Concepts](../../../../docs/core/Concepts.md): the glossary. World, pool, scene, transform, component, asset, and the reference types, each in one line.
- [Components](../Components.md): the component data layer and its access contract: declaring a component, its pool, its lifecycle procs.
- [Reference Handles](../ReferenceHandles.md): runtime handles, persistent pointers and the reference types, how they dispatch by type key and how they serialize.

[Scenes](../Scenes.md) builds on this: how pools are saved to and loaded from scene files.
