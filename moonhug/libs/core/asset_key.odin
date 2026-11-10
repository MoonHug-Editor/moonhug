package core

// One 16-byte key for any reference: what a cache keyed by guid takes.
//
//   - A reference to a whole asset (local id 0): the asset's guid.
//   - A reference to a sub-asset, one a scene file holds among them: a hash of the
//     guid and the local id. The pair it was made from is remembered, so a
//     loader handed the key finds its way back (asset_key_ref).
//
// A sub-asset's key exists only while the editor or the game runs. What is
// saved is the reference.

import "base:runtime"
import "core:hash/xxhash"

// The reference each sub-asset key was made from.
@(private = "file")
_key_refs: map[Asset_GUID]PPtr

asset_key :: proc(ref: PPtr) -> Asset_GUID {
	if ref.local_id == 0 do return ref.guid
	buf: [24]u8
	guid := ref.guid
	id := ref.local_id
	runtime.mem_copy(&buf[0], &guid, 16)
	runtime.mem_copy(&buf[16], &id, 8)
	h := xxhash.XXH3_128_default(buf[:])
	key := transmute(Asset_GUID)h
	if key not_in _key_refs {
		// Process-global: never borrows the caller's allocator.
		context.allocator = runtime.default_allocator()
		_key_refs[key] = ref
	}
	return key
}

// The keys of `refs`, for a draw's material list. A list of whole assets,
// the usual case, is the references' guids. On `allocator`.
asset_keys :: proc(refs: []PPtr, allocator := context.temp_allocator) -> []Asset_GUID {
	out := make([]Asset_GUID, len(refs), allocator)
	for r, i in refs do out[i] = asset_key(r)
	return out
}

// The reference a sub-asset key was made from, false for a whole asset's
// guid or an unknown key.
asset_key_ref :: proc(key: Asset_GUID) -> (PPtr, bool) {
	ref, ok := _key_refs[key]
	return ref, ok
}
