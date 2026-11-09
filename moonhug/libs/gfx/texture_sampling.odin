package gfx

// How a draw samples a texture: its filter, and its wrap past the edge. A
// texture carries both (Texture.filter, Texture.wrap). Auto wrap is the
// draw's default: a mesh repeats, as glTF does, and a quad clamps, so a
// sprite's edge never samples the opposite one. Full-screen draws ignore both
// and clamp: a post step reads whole images.

import sdl "vendor:sdl3"

Texture_Filter :: enum u8 {
	Linear,
	Nearest,
}

Texture_Wrap :: enum u8 {
	Auto,
	Repeat,
	Clamp,
	Mirror,
}

// One sampler per filter, wrap and anisotropy, indexed [filter][wrap][aniso].
// Anisotropic filtering is for linear mesh draws: a surface seen at a grazing
// angle samples along its stretched footprint. Wrap Auto has no samplers of
// its own: _draw_sampler resolves it first.
@(private = "file")
_samplers: [Texture_Filter][Texture_Wrap][2]^sdl.GPUSampler

@(private)
_samplers_init :: proc() -> bool {
	for filter in Texture_Filter {
		for wrap in Texture_Wrap {
			if wrap == .Auto do continue
			mode: sdl.GPUSamplerAddressMode
			switch wrap {
			case .Auto, .Repeat: mode = .REPEAT
			case .Clamp:         mode = .CLAMP_TO_EDGE
			case .Mirror:        mode = .MIRRORED_REPEAT
			}
			f: sdl.GPUFilter = filter == .Nearest ? .NEAREST : .LINEAR
			for aniso in 0 ..< 2 {
				if aniso == 1 && filter == .Nearest do continue
				// max_lod opens every mip level: SDL's zero default clamps
				// each lookup to mip 0.
				s := sdl.CreateGPUSampler(_gfx.device, sdl.GPUSamplerCreateInfo{
					min_filter        = f,
					mag_filter        = f,
					mipmap_mode       = filter == .Nearest ? .NEAREST : .LINEAR,
					address_mode_u    = mode,
					address_mode_v    = mode,
					address_mode_w    = mode,
					max_lod           = 1000,
					enable_anisotropy = aniso == 1,
					max_anisotropy    = aniso == 1 ? 8 : 0,
				})
				if s == nil do return false
				_samplers[filter][wrap][aniso] = s
			}
		}
	}
	return true
}

@(private)
_samplers_shutdown :: proc() {
	for &by_wrap in _samplers {
		for &pair in by_wrap {
			for &s in pair {
				if s != nil do sdl.ReleaseGPUSampler(_gfx.device, s)
				s = nil
			}
		}
	}
}

// The sampler a mesh or quad draw reads `t` with.
@(private)
_draw_sampler :: proc(t: ^Texture, mesh: bool) -> ^sdl.GPUSampler {
	wrap := t.wrap
	if wrap == .Auto do wrap = mesh ? .Repeat : .Clamp
	aniso := mesh && t.filter == .Linear ? 1 : 0
	return _samplers[t.filter][wrap][aniso]
}
