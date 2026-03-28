package main

import "core:os"
import "menu_gen"
import "phase_gen"
import "property_drawer_gen"
import "serialization_gen"
import "type_guid_gen"
import "decorator_gen"
import "components_gen"
import "context_menu_gen"
import "update_gen"
import "tween_gen"
import "gen_core"

packages := []string{"moonhug/editor",
	"moonhug/editor/menu",
	"moonhug/editor/inspector",
	"moonhug/app",
	"moonhug/app_editor",
	"moonhug/engine",
	"moonhug/engine_editor",
	}

main :: proc() {
	menu_data: menu_gen.MenuCollectData
	phase_data: phase_gen.PhaseCollectData
	property_drawer_data: property_drawer_gen.PropertyDrawerCollectData = {
		pkg_name = "inspector",
	}
	serialization_data: serialization_gen.SerializationCollectData = {
		pkg_name = "serialization",
	}
	type_guid_data: type_guid_gen.TypeGuidCollectData
	decorator_data: decorator_gen.DecoratorCollectData
	components_data: components_gen.ComponentCollectData
	context_menu_data: context_menu_gen.ContextMenuCollectData
	update_data: update_gen.UpdateCollectData
	tween_data: tween_gen.TweenCollectData

	menu_data.pkg_name = "editor"
	update_data.pkg_name = "app"

	defer menu_gen.cleanup(&menu_data)
	defer phase_gen.cleanup(&phase_data)
	defer property_drawer_gen.cleanup(&property_drawer_data)
	defer serialization_gen.cleanup(&serialization_data)
	defer type_guid_gen.cleanup(&type_guid_data)
	defer decorator_gen.cleanup(&decorator_data)
	defer components_gen.cleanup(&components_data)
	defer context_menu_gen.cleanup(&context_menu_data)
	defer update_gen.cleanup(&update_data)
	defer tween_gen.cleanup(&tween_data)

	for path in packages {
		pkg, ok := gen_core.ParsePackage(path)
		if !ok do os.exit(1)

		if !menu_gen.collect(pkg, path, &menu_data) do os.exit(1)
		if !phase_gen.collect(pkg, &phase_data) do os.exit(1)
		if !property_drawer_gen.collect(pkg, &property_drawer_data) do os.exit(1)
		if !serialization_gen.collect(pkg, &serialization_data) do os.exit(1)
		if !type_guid_gen.collect(pkg, path, &type_guid_data) do os.exit(1)
		if !decorator_gen.collect(pkg, &decorator_data) do os.exit(1)
		if !components_gen.collect(pkg, &components_data) do os.exit(1)
		if !context_menu_gen.collect(pkg, path, &context_menu_data) do os.exit(1)
		if !update_gen.collect(pkg, &update_data) do os.exit(1)
		if !tween_gen.collect(pkg, &tween_data) do os.exit(1)
	}

	menu_gen.collect_finalize(&menu_data)
	phase_gen.collect_finalize(&phase_data)
	property_drawer_gen.collect_finalize(&property_drawer_data)
	serialization_gen.collect_finalize(&serialization_data)
	type_guid_gen.collect_finalize(&type_guid_data)
	decorator_gen.collect_finalize(&decorator_data)
	components_gen.collect_finalize(&components_data)
	context_menu_gen.collect_finalize(&context_menu_data)
	update_gen.collect_finalize(&update_data)
	tween_gen.collect_finalize(&tween_data)

	if !menu_gen.generate(&menu_data, "moonhug/editor") do os.exit(1)
	if !phase_gen.generate_editor(&phase_data, "moonhug/editor") do os.exit(1)
	if !phase_gen.generate_app(&phase_data, "moonhug/app") do os.exit(1)
	if !property_drawer_gen.generate(&property_drawer_data, "moonhug/editor/inspector") do os.exit(1)
	if !serialization_gen.generate(&serialization_data, "moonhug/engine/serialization") do os.exit(1)
	if !type_guid_gen.generate(&type_guid_data, "moonhug/engine", "moonhug/app", "moonhug/editor") do os.exit(1)
	if !decorator_gen.generate(&decorator_data, "moonhug/editor/inspector") do os.exit(1)
	if !components_gen.generate(&components_data, "moonhug/engine") do os.exit(1)
	if !components_gen.generate_scene_file(&components_data, "moonhug/engine") do os.exit(1)
	if !components_gen.generate_component_menus(&components_data, "moonhug/editor") do os.exit(1)
	if !context_menu_gen.generate(&context_menu_data, "moonhug/editor") do os.exit(1)
	if !update_gen.generate(&update_data, "moonhug/app") do os.exit(1)
	if !tween_gen.generate(&tween_data, "moonhug/engine") do os.exit(1)
}
