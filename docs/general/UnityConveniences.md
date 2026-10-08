---
title: "Unity Conveniences"
description: "Unity editor conveniences replicated in MoonHug, such as attribute markers and default and custom IMGUI inspectors"
weight: 70
tags: ["inspector", "prebuild", "editor"]
---

Most Unity conveniences come from C# and clever Editor design choices, here are some of important features replicated in MoonHug Editor.

## C# Attributes
Odin's struct attributes and field tags + prebuild generation step cover C# Attributes feature.

## Custom IMGUI Inspectors
Dear IMGUI is used to replicate Unity's IMGUI features.

### Default Any Type Inspector
By default, all component type's fields are visible and interactable in inspector.

### Customization
- Menu
- Context Menu
- Type Inspector
- Field Decorators

## Sidecar Meta Files
Provides extra info about file asset.

## GUID Resolution
GUIDs are used for types and assets.

## asmdef and special multi place folders
Unity:
- adds all scripts in Assets folder to Assembly-CSharp assembly
- scripts in Editor folders are added to Assembly-CSharp-Editor assembly
- some other tricks for plugins, etc.

Odin has different package management structure, MoonHug solves it by providing [Plugins](../core/Plugins.md) architecture
