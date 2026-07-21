package editor

// "Assets/Extract Assets" — turns a downloaded .glb/.gltf into ready-to-use
// assets (docs/Materials.md). Embedded images are written as PLAIN FILES next
// to the model, one .mat per glTF material is created with its slots wired
// (albedo → texture; metal-rough/normal/ao/emissive → pbr.glsl rows when that
// shader asset exists, built-in Lit otherwise), one .anim AnimationClip per
// glTF animation (played by the Animation component), and one .scene
// mirroring the node hierarchy with all of the above referenced — the Unity
// model-prefab analog. Deliberately NOT Unity's read-only sub-assets:
// everything extracted is an ordinary editable asset, and existing files are
// SKIPPED — re-running never overwrites user edits. Acts on
// projectViewData.selectedFile, like Create/Scene Variant.

import cgltf "vendor:cgltf"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import engine "../engine"
import "../engine/serialization"

@(menu_separator={path="Assets", order=-45})
extract_gltf_separator :: proc() {}

@(menu_item={path="Assets/Extract Assets", order=-40, shortcut=""})
extract_gltf_menu :: proc() {
	path := projectViewData.selectedFile
	if !strings.has_suffix(path, ".glb") && !strings.has_suffix(path, ".gltf") {
		fmt.println("[Editor] Extract Assets: select a .glb/.gltf asset first")
		return
	}
	extract_gltf_assets(path)
}

// The pbr sample shader's contract (assets/shaders/pbr.glsl): material rows
// are matched by SAMPLER NAME, so these must stay in sync with the shader.
_PBR_SHADER_PATH :: "assets/shaders/pbr.glsl"

extract_gltf_assets :: proc(model_path: string) {
	dir := filepath.dir(model_path) // slice into model_path — not owned
	stem := filepath.stem(model_path)

	path_c := strings.clone_to_cstring(model_path, context.temp_allocator)
	opts := cgltf.options{}
	data, parse_res := cgltf.parse_file(opts, path_c)
	if parse_res != .success {
		fmt.printf("[Editor] Extract: failed to parse %s (%v)\n", model_path, parse_res)
		return
	}
	defer cgltf.free(data)
	if load_res := cgltf.load_buffers(opts, data, path_c); load_res != .success {
		fmt.printf("[Editor] Extract: failed to load buffers for %s (%v)\n", model_path, load_res)
		return
	}

	// 1) Every image becomes a file path: embedded ones are written out
	// (named <model>_<image-or-index>.<ext>), external uris are already
	// files next to the model.
	img_paths := make(map[^cgltf.image]string, context.temp_allocator)
	written, skipped := 0, 0
	for &img, i in data.images {
		if img.uri != nil {
			img_paths[&img], _ = filepath.join({dir, string(img.uri)}, context.temp_allocator)
			continue
		}
		if img.buffer_view == nil do continue
		ext := ".png"
		if img.mime_type != nil && string(img.mime_type) == "image/jpeg" do ext = ".jpg"
		name := fmt.tprintf("%d", i)
		if img.name != nil && len(string(img.name)) > 0 do name = string(img.name)
		out, _ := filepath.join({dir, fmt.tprintf("%s_%s%s", stem, name, ext)}, context.temp_allocator)
		img_paths[&img] = out
		if os.exists(out) {
			skipped += 1
			continue
		}
		bytes := cgltf.buffer_view_data(img.buffer_view)
		if bytes == nil do continue
		if write_err := os.write_entire_file(out, bytes[:img.buffer_view.size]); write_err != nil {
			fmt.printf("[Editor] Extract: failed to write %s\n", out)
			continue
		}
		written += 1
	}
	// Mint .meta files + guids for whatever was just written.
	engine.asset_db_refresh()

	tex_guid := proc(view: cgltf.texture_view, img_paths: ^map[^cgltf.image]string) -> engine.Asset_GUID {
		if view.texture == nil || view.texture.image_ == nil do return {}
		path, has := img_paths[view.texture.image_]
		if !has do return {}
		guid, ok := engine.asset_db_get_guid(path)
		if !ok do return {}
		return engine.Asset_GUID(guid)
	}

	pbr_shader: engine.Asset_GUID
	if guid, ok := engine.asset_db_get_guid(_PBR_SHADER_PATH); ok {
		pbr_shader = engine.Asset_GUID(guid)
	}

	// 2) One .mat per glTF material — the mesh importer orders submeshes by
	// material first-appearance, so these assign to MeshRenderer.materials
	// in file order.
	mats_written := 0
	for &m, mi in data.materials {
		out := _gltf_mat_out_path(dir, stem, &m, mi)
		if os.exists(out) {
			fmt.printf("[Editor] Extract: %s exists, skipped (delete it to re-extract)\n", out)
			continue
		}

		mat := engine.Material{color = {1, 1, 1, 1}}
		mat.properties = make([dynamic]engine.Material_Property, context.temp_allocator)
		mat.textures = make([dynamic]engine.Material_Texture, context.temp_allocator)

		metal_rough, normal, ao, emissive: engine.Asset_GUID
		metallic, roughness: f32 = 1, 1
		if m.has_pbr_metallic_roughness {
			pmr := m.pbr_metallic_roughness
			mat.color = pmr.base_color_factor
			mat.texture = tex_guid(pmr.base_color_texture, &img_paths)
			metal_rough = tex_guid(pmr.metallic_roughness_texture, &img_paths)
			metallic = pmr.metallic_factor
			roughness = pmr.roughness_factor
		}
		normal = tex_guid(m.normal_texture, &img_paths)
		ao = tex_guid(m.occlusion_texture, &img_paths)
		emissive = tex_guid(m.emissive_texture, &img_paths)

		needs_pbr := metal_rough != {} || normal != {} || ao != {} || emissive != {}
		if needs_pbr && pbr_shader != {} {
			mat.custom_shader = pbr_shader
			append(&mat.textures, engine.Material_Texture{name = "metal_rough_tex", texture = metal_rough})
			append(&mat.textures, engine.Material_Texture{name = "normal_tex", texture = normal})
			append(&mat.textures, engine.Material_Texture{name = "ao_tex", texture = ao})
			append(&mat.textures, engine.Material_Texture{name = "emissive_tex", texture = emissive})
			// pbr.glsl treats 0 as "unset, fall back to 1" for factors —
			// nudge a real 0 to near-zero so it survives.
			factor := proc(f: f32) -> f32 { return f <= 0 ? 0.001 : f }
			ef := m.emissive_factor
			has_emissive := emissive != {} || ef != {0, 0, 0}
			append(&mat.properties, engine.Material_Property{name = "emissive_color", value = {ef.r, ef.g, ef.b, has_emissive ? 1 : 0}})
			append(&mat.properties, engine.Material_Property{name = "metallic", value = {factor(metallic), 0, 0, 0}})
			append(&mat.properties, engine.Material_Property{name = "roughness", value = {factor(roughness), 0, 0, 0}})
			append(&mat.properties, engine.Material_Property{name = "normal_strength", value = {normal != {} ? 1 : 0, 0, 0, 0}})
		} else {
			mat.shader = .Lit
			if needs_pbr {
				fmt.printf("[Editor] Extract: %s not found — %s gets built-in Lit with albedo only\n", _PBR_SHADER_PATH, out)
			}
		}

		if !serialization.write_asset_to_path(out, engine.get_guid_by_type_key(engine.TypeKey.Material), mat) {
			fmt.printf("[Editor] Extract: failed to write %s\n", out)
			continue
		}
		mats_written += 1
	}
	// 3) One .anim AnimationClip per glTF animation. Channel targets are the
	// glTF node-name paths ("Root/Bone"), matching child transforms under the
	// object that carries the Animation component (Unity's curve bindings).
	anims_written := 0
	for &an, ai in data.animations {
		out := _gltf_anim_out_path(dir, stem, &an, ai)
		if os.exists(out) {
			fmt.printf("[Editor] Extract: %s exists, skipped (delete it to re-extract)\n", out)
			continue
		}
		clip, ok := engine.animation_clip_from_gltf(data, &an)
		if !ok {
			fmt.printf("[Editor] Extract: no usable channels in %s\n", out)
			continue
		}
		if !serialization.write_asset_to_path(out, engine.get_guid_by_type_key(engine.TypeKey.AnimationClip), clip) {
			fmt.printf("[Editor] Extract: failed to write %s\n", out)
			continue
		}
		anims_written += 1
	}
	engine.asset_db_refresh()

	// 4) <stem>.scene mirroring the glTF node hierarchy (the Unity
	// model-prefab analog): root MeshFilter/MeshRenderer wired to the .glb and
	// the extracted materials in submesh order, an Animation component with
	// the first clip, node children so clip target paths resolve. References
	// resolve by the extract paths above, so re-running after a partial
	// extract (or with pre-existing assets) still wires everything available.
	scenes_written := 0
	scene_out, _ := filepath.join({dir, fmt.tprintf("%s.scene", stem)}, context.temp_allocator)
	if os.exists(scene_out) {
		fmt.printf("[Editor] Extract: %s exists, skipped (delete it to re-extract)\n", scene_out)
	} else {
		path_guid := proc(path: string) -> (g: engine.Asset_GUID) {
			if id, ok := engine.asset_db_get_guid(path); ok do g = engine.Asset_GUID(id)
			return
		}
		mesh_guid := path_guid(model_path)

		submesh_mats := engine.gltf_submesh_materials(data)
		mats := make([dynamic]engine.Asset_GUID, context.temp_allocator)
		for m in submesh_mats {
			g: engine.Asset_GUID
			if m != nil {
				mi := int(cgltf.material_index(data, m))
				g = path_guid(_gltf_mat_out_path(dir, stem, m, mi))
			}
			append(&mats, g)
		}

		clip_guid: engine.Asset_GUID
		if len(data.animations) > 0 {
			clip_guid = path_guid(_gltf_anim_out_path(dir, stem, &data.animations[0], 0))
		}

		if engine.scene_from_gltf(data, stem, mesh_guid, mats[:], clip_guid, scene_out) {
			scenes_written += 1
		} else {
			fmt.printf("[Editor] Extract: failed to write %s\n", scene_out)
		}
	}
	engine.asset_db_refresh()

	fmt.printf("[Editor] Extract %s: %d texture(s) written, %d already existed, %d material(s), %d animation clip(s), %d scene(s) created\n",
		model_path, written, skipped, mats_written, anims_written, scenes_written)
}

// Extraction output paths, shared by the writers and the scene reference
// wiring: "<model>_<name-or-index>.mat" / ".anim" next to the model
// (temp-allocated).
_gltf_mat_out_path :: proc(dir, stem: string, m: ^cgltf.material, index: int) -> string {
	name := fmt.tprintf("%d", index)
	if m.name != nil && len(string(m.name)) > 0 do name = string(m.name)
	out, _ := filepath.join({dir, fmt.tprintf("%s_%s.mat", stem, name)}, context.temp_allocator)
	return out
}

_gltf_anim_out_path :: proc(dir, stem: string, an: ^cgltf.animation, index: int) -> string {
	name := fmt.tprintf("%d", index)
	if an.name != nil && len(string(an.name)) > 0 do name = string(an.name)
	out, _ := filepath.join({dir, fmt.tprintf("%s_%s.anim", stem, name)}, context.temp_allocator)
	return out
}
