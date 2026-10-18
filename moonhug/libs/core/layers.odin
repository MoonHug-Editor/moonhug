package core

// Named layers per domain (plugins/engine/docs/Layers.md).
//
// A domain is one system that sorts objects into 32 layers: "render" for the
// engine's views, "physics" for the 2D and 3D colliders. Each domain has a
// list of 32 names. The owner registers a pointer to its list once and
// rewrites the list in place when the names change, so every reader sees the
// change with no copy to keep in sync. The engine owns both lists and fills
// them from the project's Layers asset (plugins/engine/layers_asset.odin).
//
// Readers are the layer picker (decor:layers) and anything that turns a name
// into a bit. The registry knows no domain by name.

import "base:runtime"
import "core:fmt"
import "core:strings"

LAYER_COUNT :: 32

@(private = "file")
_Layer_Domain :: struct {
	names:  ^[LAYER_COUNT]string,
	// Layers the picker never lists (the render domain's Editor layer).
	hidden: u32,
}

@(private = "file")
_layer_domains: map[string]_Layer_Domain

// Registers `domain` with the list of names it owns. `names` must outlive the
// program (a package-level var). `hidden` is a mask of layers the picker does
// not list. Registering a domain again with the same list is allowed, with
// another list is a bug and panics.
layer_domain_register :: proc(domain: string, names: ^[LAYER_COUNT]string, hidden: u32 = 0) {
	fmt.assertf(names != nil, "layer domain %q registered with no names", domain)
	if _layer_domains == nil do _layer_domains = make(map[string]_Layer_Domain, runtime.default_allocator())
	if prev, has := _layer_domains[domain]; has {
		fmt.assertf(prev.names == names, "layer domain %q is already registered with another name list", domain)
		_layer_domains[domain] = _Layer_Domain{names = names, hidden = hidden}
		return
	}
	_layer_domains[strings.clone(domain, runtime.default_allocator())] = _Layer_Domain{names = names, hidden = hidden}
}

// The 32 names of `domain`, nil when no owner registered it. An empty name is
// an unused layer. The list is the owner's own: read it, do not write it.
layer_names :: proc(domain: string) -> ^[LAYER_COUNT]string {
	d, has := _layer_domains[domain]
	if !has do return nil
	return d.names
}

// The mask of layers in `domain` the picker does not list.
layer_hidden_mask :: proc(domain: string) -> u32 {
	return _layer_domains[domain].hidden
}

// The name of `layer` (0..31) in `domain`. Empty for an unused layer or an
// unknown domain.
layer_name :: proc(domain: string, layer: int) -> string {
	names := layer_names(domain)
	if names == nil || layer < 0 || layer >= LAYER_COUNT do return ""
	return names[layer]
}

// The layer named `name` in `domain`, -1 when no layer has that name.
layer_index :: proc(domain: string, name: string) -> int {
	names := layer_names(domain)
	if names == nil || name == "" do return -1
	for n, i in names {
		if n == name do return i
	}
	return -1
}
