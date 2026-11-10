package engine

// A noise map: a texture made from a few numbers, not from an image file.
// Clouds, marble, lava, a mask. It is used where a texture is used: a
// material's texture slot can point at one, and texture_load makes its
// pixels (texture2d.odin).
//
//   - As a file it is a `.noise` asset. As a sub-asset it is a record
//     of type "noise" in a scene file (scene_sub_assets.odin). Both read
//     through asset_source, so they load the same way.
//   - The pattern tiles: its left edge continues at its right, its top at its
//     bottom, so it wraps a sphere or repeats on a floor without a seam.
//   - Each pixel is a value from 0 to 1, shown as a color between `low` and
//     `high`.

import "core:encoding/json"
import "core:math"
import "core:math/noise"
import "core:os"
import "core:thread"

Noise_Kind :: enum u8 {
	Simplex,  // soft clouds
	Ridged,   // sharp bright veins: marble, lightning, lava cracks
	Cellular, // cells: stones, scales, bubbles
}

@(typ_guid={guid = "2eb41971-9bc0-4aac-83e0-b274fdff8f0f", menu_assets_create = {menu_name = "Noise Map", file_name = "New Noise Map.noise", order = -5}})
NoiseMap :: struct {
	kind:       Noise_Kind,
	// The texture's width and height in pixels.
	size:       i32,
	// How many features fit across the texture.
	frequency:  f32,
	// Layers of detail, each `lacunarity` times finer and `gain` times
	// weaker than the one before.
	octaves:    i32,
	lacunarity: f32,
	gain:       f32,
	seed:       i32,
	// The colors of the lowest and the highest value.
	low:        [4]f32 `decor:color()`,
	high:       [4]f32 `decor:color()`,
}

NOISE_MAP_DEFAULT :: NoiseMap{kind = .Simplex, size = 256, frequency = 4, octaves = 4, lacunarity = 2, gain = 0.5, low = {0, 0, 0, 1}, high = {1, 1, 1, 1}}

NOISE_MAP_SIZE_MAX :: 2048

type_reset_NoiseMap :: proc(n: ^NoiseMap) {
	n^ = NOISE_MAP_DEFAULT
}

// Keeps the numbers in the range the generator works in.
type_on_validate_NoiseMap :: proc(n: ^NoiseMap) {
	n.size = clamp(n.size, 4, NOISE_MAP_SIZE_MAX)
	n.frequency = max(n.frequency, 0.01)
	n.octaves = clamp(n.octaves, 1, 10)
	n.lacunarity = max(n.lacunarity, 1)
	n.gain = clamp(n.gain, 0, 1)
}

// A noise map from its JSON: the defaults, then what the text holds.
noise_map_parse :: proc(data: []byte) -> (NoiseMap, bool) {
	n := NOISE_MAP_DEFAULT
	if json.unmarshal(data, &n, .JSON, context.temp_allocator) != nil do return {}, false
	type_on_validate_NoiseMap(&n)
	return n, true
}

// The noise map's pixels: size x size, RGBA, 8 bits a channel, row by row.
// The rows are split between the machine's cores: a 512 map with 5 octaves
// is 1.3 million noise samples, too many for one core while a number is
// dragged in the inspector.
noise_map_pixels :: proc(n: NoiseMap, allocator := context.allocator) -> []u8 {
	n := n
	type_on_validate_NoiseMap(&n)
	size := int(n.size)
	out := make([]u8, size * size * 4, allocator)
	// Where each column is on its circle (_noise_tiled): the same for every row.
	circle := make([][2]f64, size, context.temp_allocator)
	for &c, x in circle do c = _circle((f64(x) + 0.5) / f64(size))

	bands := 1
	when thread.IS_SUPPORTED {
		bands = clamp(min(os.get_processor_core_count(), size / _NOISE_BAND_ROWS_MIN), 1, _NOISE_BANDS_MAX)
	}
	jobs: [_NOISE_BANDS_MAX]_Noise_Band
	threads: [_NOISE_BANDS_MAX]^thread.Thread
	for i in 0 ..< bands do jobs[i] = _Noise_Band{n = n, out = out, circle = circle, first = i * size / bands, end = (i + 1) * size / bands}
	// This thread takes the last band, the others one each.
	for i in 0 ..< bands - 1 do threads[i] = thread.create_and_start_with_poly_data(&jobs[i], _noise_band)
	_noise_band(&jobs[bands - 1])
	for i in 0 ..< bands - 1 {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}
	return out
}

@(private = "file")
_NOISE_BANDS_MAX :: 16

// A band shorter than this is not worth a thread.
@(private = "file")
_NOISE_BAND_ROWS_MIN :: 32

// The rows [first, end) of a noise map's pixels: what one thread fills.
@(private = "file")
_Noise_Band :: struct {
	n:          NoiseMap,
	out:        []u8,
	circle:     [][2]f64,
	first, end: int,
}

@(private = "file")
_noise_band :: proc(band: ^_Noise_Band) {
	n := band.n
	size := int(n.size)
	for y in band.first ..< band.end {
		v := (f64(y) + 0.5) / f64(size)
		cv := _circle(v)
		for x in 0 ..< size {
			u := (f64(x) + 0.5) / f64(size)
			value := clamp(_noise_value(n, u, v, band.circle[x], cv), 0, 1)
			i := (y * size + x) * 4
			for c in 0 ..< 4 {
				channel := n.low[c] + (n.high[c] - n.low[c]) * value
				band.out[i + c] = u8(clamp(channel, 0, 1) * 255 + 0.5)
			}
		}
	}
}

// The value at (u, v), each from 0 to 1 across the texture. About 0 to 1.
noise_map_value :: proc(n: NoiseMap, u, v: f64) -> f32 {
	return _noise_value(n, u, v, _circle(u), _circle(v))
}

// noise_map_value with the circle points of u and v given (_circle).
@(private = "file")
_noise_value :: proc(n: NoiseMap, u, v: f64, cu, cv: [2]f64) -> f32 {
	sum, amp, norm: f32
	freq := f64(n.frequency)
	amp = 1
	for octave in 0 ..< n.octaves {
		seed := i64(n.seed) + i64(octave) * 7919
		layer: f32
		switch n.kind {
		case .Simplex:  layer = _noise_tiled(seed, cu, cv, freq) * 0.5 + 0.5
		case .Ridged:   layer = 1 - abs(_noise_tiled(seed, cu, cv, freq))
		case .Cellular: layer = _noise_cells(seed, u, v, freq)
		}
		sum += layer * amp
		norm += amp
		amp *= n.gain
		freq *= f64(n.lacunarity)
	}
	value := sum / max(norm, 0.0001)
	// Ridges read better sharpened: the veins stay thin.
	if n.kind == .Ridged do value = value * value
	return value
}

// The point of a unit circle that `t`, from 0 to 1, is at: its cosine and sine.
@(private = "file")
_circle :: proc(t: f64) -> [2]f64 {
	a := t * math.TAU
	return {math.cos(a), math.sin(a)}
}

// Simplex noise that tiles: u and v each walk a circle (cu, cv: _circle) in
// four dimensions, so each axis comes back to where it started. About -1 to 1.
@(private = "file")
_noise_tiled :: proc(seed: i64, cu, cv: [2]f64, freq: f64) -> f32 {
	r := freq / math.TAU
	return noise.noise_4d_fallback(seed, {cu.x * r, cu.y * r, cv.x * r, cv.y * r})
}

// Cellular noise that tiles: the distance to the nearest of the points
// scattered one per cell, on a grid of round(freq) cells that wraps. 0 at a
// point, towards 1 between points.
@(private = "file")
_noise_cells :: proc(seed: i64, u, v, freq: f64) -> f32 {
	cells := max(int(math.round(freq)), 1)
	px := u * f64(cells)
	py := v * f64(cells)
	cx := int(math.floor(px))
	cy := int(math.floor(py))
	best := f64(4)
	for dy in -1 ..= 1 {
		for dx in -1 ..= 1 {
			gx := cx + dx
			gy := cy + dy
			// The cell's point, the same for a cell and its wrapped twin.
			wx := ((gx % cells) + cells) % cells
			wy := ((gy % cells) + cells) % cells
			h := _hash2(seed, wx, wy)
			fx := f64(gx) + f64(h & 0xffff) / 65535
			fy := f64(gy) + f64((h >> 16) & 0xffff) / 65535
			d := (fx - px) * (fx - px) + (fy - py) * (fy - py)
			best = min(best, d)
		}
	}
	return f32(min(math.sqrt(best), 1))
}

@(private = "file")
_hash2 :: proc(seed: i64, x, y: int) -> u64 {
	h := u64(seed) * 0x9E3779B97F4A7C15 + u64(x) * 0xBF58476D1CE4E5B9 + u64(y) * 0x94D049BB133111EB
	h ~= h >> 31
	h *= 0xD6E8FEB86659FD93
	h ~= h >> 32
	return h
}
