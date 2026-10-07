package inspector

// Field tags: the keys MoonHug reads from struct field tags.
//
// Every key is declared once, as a package-level Field_Tag constant with a doc
// comment, and read only through tag_value and tag_has with that constant.
// The prebuild (moonhug/prebuild/field_tags_gen) checks every field tag in the
// scanned code against the declarations and writes docs/reference/field_tags
// from them. A plugin declares its own keys the same way, in its editor/ part.
//
// A tag is a list of keys separated by whitespace, in one of three forms:
//
//     ref:"Transform"          Value: key:"text"
//     expand                   Flag: a bare word
//     decor:min(0.5)           Call: key:name(args)
//
// Value keys come first. Odin's reflect.struct_tag_lookup, which tag_value and
// core:encoding/json both use, stops at the first bare word, call or line
// break, so a Value key after one is never read. The prebuild checks it.

import "core:reflect"

// How a key is written in a field tag.
Field_Tag_Form :: enum {
	Value, // key:"text"
	Flag,  // key, a bare word. key:"" reads the same.
	Call,  // key:name(args) or key:name, and it may repeat in one tag
}

// One field tag key and the form it is written in.
Field_Tag :: struct {
	key:  string,
	form: Field_Tag_Form,
}

// Controls whether the inspector shows the field.
//
// `inspect:"-"` hides it. Any other value, usually `inspect:""`, shows a field
// that `json:"-"` would hide.
TAG_INSPECT :: Field_Tag{key = "inspect", form = .Value}

// Odin's core:encoding/json key: the field's name in JSON, and options.
//
// `json:"name"` renames the field's key and `json:"name,omitempty"` leaves an
// empty value out. MoonHug writes scenes, assets, settings and undo snapshots
// (undo.capture_json) with core:encoding/json, so `json:"-"` means the field is
// not saved and is not part of undo snapshots: undo and redo never restore it,
// and code that keeps state in such a field rebuilds it after an apply, the way
// reference handles are rebound by the resolver. The inspector also hides a
// `json:"-"` field unless it carries `inspect`. MoonHug interprets only `-`,
// the rest is Odin's.
TAG_JSON :: Field_Tag{key = "json", form = .Value}

// Says what a reference field accepts.
//
// For Ref_Local, Ref and Asset_GUID fields. The text is a comma list, each item
// a component type by name or a capability tag with an `@` sigil:
// `ref:"Animation"`, `ref:"Animation,AudioSource"`, `ref:"@Output"` (every
// component declaring `ref_tags="Output"`). The picker offers only what the
// list admits, and a property write is checked against it. On an Asset_GUID
// field it lists the scene assets whose root carries one of the components.
// docs/core/ObjectPicker.md explains the pickers.
TAG_REF :: Field_Tag{key = "ref", form = .Value}

// Names components an object must carry for a reference field to offer it.
//
// The same list grammar as `ref`. `ref` says what is stored, `has` says which
// objects qualify: `ref:"Transform" has:"@Output"` stores the Transform of an
// object that carries an Output component.
@(reserved)
TAG_HAS :: Field_Tag{key = "has", form = .Value}

// Limits which picker tab can assign a Ref field.
//
// `pick:"scene"` assigns scene objects only, `pick:"project"` assets only.
// Without it both tabs assign.
@(reserved)
TAG_PICK :: Field_Tag{key = "pick", form = .Value}

// Limits an Asset_GUID field to files with the given extensions.
//
// A comma list without dots: `ext:"glb,gltf"`. The picker lists only matching
// files and drag and drop refuses the others. Without it, or empty, every file
// is admitted.
TAG_EXT :: Field_Tag{key = "ext", form = .Value}

// Gives an Asset_GUID field a foldout that edits the referenced asset in place.
//
// On an array of Asset_GUID each element gets one. The asset's document opens
// under the row, edited with the same undo and live preview as in the Project
// inspector. Opt-in per field: a material slot wants it, a mesh slot does not.
TAG_EXPAND :: Field_Tag{key = "expand", form = .Flag}

// Draws a nested struct's fields at the parent's level instead of under a
// foldout.
//
// Written `inline:""` or as a bare `inline`, both read the same.
TAG_INLINE :: Field_Tag{key = "inline", form = .Flag}

// Runs a decorator on the field's row, which draws something around the field
// or changes how it draws.
//
// `decor:name(args)` calls the inspector proc `decorator_<name>` with the
// row's draw context first and then the arguments: `decor:min(0.5)`,
// `decor:range(0, 1)`, `decor:header(text="Stats")`. A tag may carry several.
// They run in tag order before the field draws and in reverse order after it.
// `decor:button(proc_name, label="", row=0, weight=1)` adds an action button
// that calls `proc_name`. The decorators are the procs named
// `decorator_<name>` in package inspector.
TAG_DECOR :: Field_Tag{key = "decor", form = .Call}

// The text `t` carries in `tag`. A Value key gives its text, a Call key its
// first call as written (`min(0.5)`), a Flag key "". ok is false when the tag
// does not carry the key.
tag_value :: proc(tag: reflect.Struct_Tag, t: Field_Tag) -> (value: string, ok: bool) {
	switch t.form {
	case .Value:
		return reflect.struct_tag_lookup(tag, t.key)
	case .Flag:
		return "", tag_has(tag, t)
	case .Call:
		rest := string(tag)
		for {
			key, text, next, more := _tag_next(rest)
			if !more do return "", false
			if key == t.key && text != "" && text[0] != '"' do return text, true
			rest = next
		}
	}
	return "", false
}

// Whether `tag` carries `t`, in any spelling the form accepts.
tag_has :: proc(tag: reflect.Struct_Tag, t: Field_Tag) -> bool {
	if t.form == .Value {
		_, ok := reflect.struct_tag_lookup(tag, t.key)
		return ok
	}
	rest := string(tag)
	for {
		key, _, next, more := _tag_next(rest)
		if !more do return false
		if key == t.key do return true
		rest = next
	}
}

// Splits the first key off `s`. `text` is what follows the key's colon, quotes
// included for a value, "" for a bare word. A quoted string or a call's
// parentheses keep their whitespace.
@(private = "file")
_tag_next :: proc(s: string) -> (key, text, rest: string, ok: bool) {
	space :: proc(c: u8) -> bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' }
	i := 0
	for i < len(s) && space(s[i]) do i += 1
	if i >= len(s) do return "", "", "", false
	start := i
	for i < len(s) && !space(s[i]) && s[i] != ':' do i += 1
	key = s[start:i]
	if i < len(s) && s[i] == ':' {
		i += 1
		from := i
		depth := 0
		for i < len(s) {
			c := s[i]
			if c == '"' {
				i += 1
				for i < len(s) && s[i] != '"' {
					if s[i] == '\\' do i += 1
					i += 1
				}
				i += 1
				continue
			}
			if c == '(' do depth += 1
			if c == ')' do depth -= 1
			if depth <= 0 && space(c) do break
			i += 1
		}
		i = min(i, len(s))
		text = s[from:i]
	}
	return key, text, s[i:], true
}
