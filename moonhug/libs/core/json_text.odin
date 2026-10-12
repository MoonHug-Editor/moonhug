package core

// Canonical JSON text shared by every serialize path, so a value writes the
// same bytes whichever path produced it.

// Canonicalizes float text in marshaled JSON. Core's writer emits floats at
// fixed width — f32 fields with 8 fraction digits, f64 (every json.Value
// number) with 16 — so the same value serializes to different text depending
// on whether it took the typed-struct or the json.Value path, and one scene
// file mixes both. Trimming trailing fraction zeros converges the two forms.
// One digit always stays after the '.' so the token reparses as Float, not
// Integer (override diffs compare parsed values, and Integer(1) != Float(1.0)).
// Numbers inside strings and exponent forms are untouched. Returns a new
// allocation.
json_canonicalize_floats :: proc(data: []byte, allocator := context.allocator) -> []byte {
	out := make([dynamic]byte, 0, len(data), allocator)
	in_string := false
	i := 0
	for i < len(data) {
		c := data[i]
		if in_string {
			append(&out, c)
			if c == '\\' && i + 1 < len(data) {
				append(&out, data[i + 1])
				i += 2
				continue
			}
			if c == '"' do in_string = false
			i += 1
			continue
		}
		if c == '"' {
			in_string = true
			append(&out, c)
			i += 1
			continue
		}
		if c != '-' && (c < '0' || c > '9') {
			append(&out, c)
			i += 1
			continue
		}
		start := i
		dot := -1
		exp := false
		scan: for i < len(data) {
			switch data[i] {
			case '0' ..= '9', '-', '+':
			case '.':
				if dot < 0 do dot = i - start
			case 'e', 'E':
				exp = true
			case:
				break scan
			}
			i += 1
		}
		tok := data[start:i]
		end := len(tok)
		if dot >= 0 && !exp {
			for end > dot + 2 && tok[end - 1] == '0' do end -= 1
		}
		append(&out, ..tok[:end])
	}
	return out[:]
}
