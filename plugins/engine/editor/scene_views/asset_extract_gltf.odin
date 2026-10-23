package scene_views

// "Assets/Extract Assets" — turns a downloaded .glb/.gltf into ready-to-use
// assets (plugins/engine/docs/Materials.md). Embedded images are written as PLAIN FILES next
// to the model, one .mat per glTF material is created with its slots wired
// (the built-in Lit: base color → texture and color, metal-rough, normal,
// occlusion and emissive → the material's lit block, alpha mode MASK → alpha
// clipping), one clip per glTF animation
// (with the animation package installed: importers.gltf_clip_extractor),
// and one .scene mirroring the node hierarchy with all of the above
// referenced — the Unity model-prefab analog. Deliberately NOT Unity's read-only sub-assets:
// everything extracted is an ordinary editable asset, and existing files are
// SKIPPED — re-running never overwrites user edits. Acts on
// the project view's active path (session.project_active), like Create/Scene Variant.

import "moonhug:editor/session"
import cgltf "vendor:cgltf"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import engine "moonhug:packages/engine"
import asset_pipeline "moonhug:editor/assets"
import "moonhug:packages/engine/editor/importers"
import gfx "moonhug:libs/gfx"
import "moonhug:libs/serialization"

@(menu_separator={path="Assets", order=-45})
extract_gltf_separator :: proc() {}

@(menu_item={path="Assets/Extract Assets", order=-40, shortcut=""})
extract_gltf_menu :: proc() {
	path := session.project_active()
	if !strings.has_suffix(path, ".glb") && !strings.has_suffix(path, ".gltf") {
		fmt.println("[Editor] Extract Assets: select a .glb/.gltf asset first")
		return
	}
	extract_gltf_assets(path)
}


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
	missing := 0
	for &img, i in data.images {
		if img.uri != nil {
			path, _ := filepath.join({dir, string(img.uri)}, context.temp_allocator)
			// An external image the model names but that is not beside it:
			// every map reading it stays empty, said once here rather than
			// found later as a flat material.
			if !os.exists(path) {
				fmt.printf("[Editor] Extract: image %s is missing beside the model: the maps that read it stay empty\n", string(img.uri))
				missing += 1
				continue
			}
			img_paths[&img] = path
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
	asset_pipeline.asset_db_refresh()

	tex_guid := proc(view: cgltf.texture_view, img_paths: ^map[^cgltf.image]string) -> engine.Asset_GUID {
		if view.texture == nil || view.texture.image_ == nil do return {}
		if view.texture.image_ not_in img_paths do return {} // missing beside the model, reported above
		// Meshes carry two texture coordinate sets: a map on a third or later
		// one has nothing to read through and is left out.
		if view.texcoord > 1 {
			fmt.printf("[Editor] Extract: a map on texture coordinate set %d skipped (meshes carry two)\n", view.texcoord)
			return {}
		}
		path, has := img_paths[view.texture.image_]
		if !has do return {}
		guid, ok := engine.asset_db_get_guid(path)
		if !ok do return {}
		return engine.Asset_GUID(guid)
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

		// The built-in Lit: glTF's metal/roughness model, its factors stored
		// the way the material inspector authors them (colors in sRGB,
		// smoothness instead of roughness).
		mat := engine.Material{shader = .Lit, color = {1, 1, 1, 1}, alpha_cutoff = engine.MATERIAL_ALPHA_CUTOFF_DEFAULT, lit = engine.MATERIAL_LIT_DEFAULT}
		mat.lit.metallic = 1
		mat.lit.smoothness = 0
		if m.has_pbr_metallic_roughness {
			pmr := m.pbr_metallic_roughness
			mat.color = gfx.linear_to_srgb(pmr.base_color_factor)
			mat.texture = tex_guid(pmr.base_color_texture, &img_paths)
			mat.lit.metallic_roughness_map = tex_guid(pmr.metallic_roughness_texture, &img_paths)
			mat.lit.metallic = pmr.metallic_factor
			mat.lit.smoothness = 1 - pmr.roughness_factor
		}
		mat.lit.normal_map = tex_guid(m.normal_texture, &img_paths)
		mat.lit.normal_scale = m.normal_texture.texture != nil ? m.normal_texture.scale : 1
		mat.lit.occlusion_map = tex_guid(m.occlusion_texture, &img_paths)
		mat.lit.occlusion_strength = m.occlusion_texture.texture != nil ? m.occlusion_texture.scale : 1
		mat.lit.emission_map = tex_guid(m.emissive_texture, &img_paths)
		// The set each map reads: glTF's texCoord (a baked occlusion atlas
		// usually sits on the second).
		uv_set := proc(view: cgltf.texture_view) -> engine.Material_Uv_Set { return view.texcoord == 1 ? .Second : .First }
		if m.has_pbr_metallic_roughness {
			mat.lit.texture_uv_set = uv_set(m.pbr_metallic_roughness.base_color_texture)
			mat.lit.metallic_roughness_uv_set = uv_set(m.pbr_metallic_roughness.metallic_roughness_texture)
		}
		mat.lit.normal_uv_set = uv_set(m.normal_texture)
		mat.lit.occlusion_uv_set = uv_set(m.occlusion_texture)
		mat.lit.emission_uv_set = uv_set(m.emissive_texture)
		ef := m.emissive_factor
		mat.lit.emission_color = gfx.linear_to_srgb({ef.r, ef.g, ef.b, 1})
		// glTF MASK: texels below the cutoff are not drawn (alpha clipping).
		if m.alpha_mode == .mask {
			mat.alpha_clip = true
			mat.alpha_cutoff = m.alpha_cutoff
		}
		// glTF doubleSided: both faces drawn, no back-face culling.
		if m.double_sided do mat.render_face = .Both
		// KHR_texture_transform on the base colour, taken for every map of
		// the material, and a sampler clamped to the edge (a decal placed by
		// the transform, its edge pixels filling the rest).
		if m.has_pbr_metallic_roughness {
			if v := m.pbr_metallic_roughness.base_color_texture; v.has_transform {
				mat.lit.uv_scale = v.transform.scale
				mat.lit.uv_offset = v.transform.offset
			}
			if v := m.pbr_metallic_roughness.base_color_texture; v.texture != nil && v.texture.sampler != nil && v.texture.sampler.wrap_s == .clamp_to_edge {
				mat.lit.uv_clamp = true
			}
		}
		// KHR_materials_transmission: glass. Transparent and refracting a
		// little (a pane's thickness), the transmitted light in place of
		// the diffuse by the factor, as glTF has it: the alpha of a
		// refracting material is how much of its diffuse body remains, its
		// highlights and reflections stay whole.
		if m.has_transmission && m.transmission.transmission_factor > 0 {
			mat.surface = .Transparent
			mat.color.a = 1 - min(m.transmission.transmission_factor, 1)
			mat.refraction = 0.02
		}

		if !serialization.write_asset_to_path(out, engine.get_guid_by_type_key(engine.TypeKey.Material), mat) {
			fmt.printf("[Editor] Extract: failed to write %s\n", out)
			continue
		}
		mats_written += 1
	}
	// 3) One .anim clip per glTF animation, from the animation package.
	// Channel targets are the glTF node-name paths ("Root/Bone"), matching
	// child transforms under the object that plays the clip (Unity's curve
	// bindings).
	anims_written := 0
	clips := importers.gltf_clip_extractor
	if clips.write != nil {
		for &an, ai in data.animations {
			// REPLACED, not skipped: a clip is a generated file, and
			// re-exporting the model has to be able to refresh its curves.
			// What an author set — wrap, frame rate, cycle offset, trim —
			// lives in the .meta beside it and rides through untouched.
			out := _gltf_anim_out_path(dir, stem, &an, ai)
			if !clips.write(data, &an, out) {
				fmt.printf("[Editor] Extract: %s not written (no usable channels, or the write failed)\n", out)
				continue
			}
			anims_written += 1
		}
	}
	asset_pipeline.asset_db_refresh()

	// 4) <stem>.scene mirroring the glTF node hierarchy (the Unity
	// model-prefab analog): mesh nodes wired to their part of the .glb and
	// the extracted materials, an Animation component with the first clip on
	// the root, so clips move real geometry. References resolve by the
	// extract paths above, so re-running after a partial extract (or with
	// pre-existing assets) still wires everything available.
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

		// Indexed by glTF material index (scene_from_gltf's contract).
		mats := make([dynamic]engine.Asset_GUID, context.temp_allocator)
		for &m, mi in data.materials {
			append(&mats, path_guid(_gltf_mat_out_path(dir, stem, &m, mi)))
		}

		// The engine authors the scene. The component that plays the first
		// clip comes from the animation package, wired onto the root here
		// (scene_from_gltf's decorate_root seam).
		clip_ref: engine.PPtr
		if len(data.animations) > 0 && clips.decorate != nil {
			clip_ref.guid = path_guid(_gltf_anim_out_path(dir, stem, &data.animations[0], 0))
		}
		play_first_clip := proc(root: engine.Transform_Handle, user: rawptr) {
			clip := (cast(^engine.PPtr)user)^
			if clip == {} do return
			importers.gltf_clip_extractor.decorate(root, clip)
		}

		if engine.scene_from_gltf(data, stem, mesh_guid, mats[:], scene_out, play_first_clip, &clip_ref) {
			scenes_written += 1
		} else {
			fmt.printf("[Editor] Extract: failed to write %s\n", scene_out)
		}
	}
	asset_pipeline.asset_db_refresh()

	fmt.printf("[Editor] Extract %s: %d texture(s) written, %d already existed, %d missing, %d material(s), %d animation clip(s), %d scene(s) created\n",
		model_path, written, skipped, missing, mats_written, anims_written, scenes_written)
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
