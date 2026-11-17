package audio

// The Audio Mixer asset (docs/assets/AudioMixer.md): a tree of groups that
// sounds play through. A group has a volume, a mute and a list of effects,
// and its sound goes on through its parent to the Master, each group's volume
// and effects applied on the way. An AudioSource picks the group it plays
// through in `output`, a reference to the group: the mixer file's guid and the
// group's id.
//
// The groups are a flat list in the file, each naming its parent by id, the
// Master first. An id is minted when a group is added and never reused, so a
// source's output survives groups renamed, moved or removed around it.
// How the groups play is in mixer_runtime.odin.

import "core:strings"

@(typ_guid={guid = "cf6fc86b-7790-48e0-b534-e4508d1cf3bd"})
@(asset={menu = "Audio Mixer", file = "New Audio Mixer.mixer", order = -1, no_embed = true})
AudioMixer :: struct {
	// The Master first, then every other group after its parent.
	groups:  [dynamic]Mixer_Group,
	// The id the next group gets.
	next_id: i64 `inspect:"-"`,
}

Mixer_Group :: struct {
	id:      i64 `inspect:"-"`,
	parent:  i64 `inspect:"-"`, // 0 for the Master
	name:    string,
	// In decibels: 0 leaves the sound as it is, -6 about halves it, -80 is
	// silence.
	volume:  f32 `decor:range(-80, 20)`,
	mute:    bool,
	// Applied in order, after the volume.
	effects: [dynamic]Mixer_Effect,
}

// One effect of a group. A zero field means its default, so an effect just
// picked from the list works as it is.
Mixer_Effect :: union #no_nil {
	Mixer_Low_Pass,
	Mixer_High_Pass,
	Mixer_Duck,
}

// Lets through what is below `cutoff` and muffles what is above it.
@(typ_guid={guid = "6a733931-2100-44b9-92f8-efa80088c639"})
Mixer_Low_Pass :: struct {
	cutoff:    f32 `decor:range(10, 22000)`, // Hz, 5000 when zero
	// 1 is a plain slope, more rings at the cutoff.
	resonance: f32 `decor:range(0.1, 10)`, // 1 when zero
}

// Lets through what is above `cutoff` and thins out what is below it.
@(typ_guid={guid = "b8c149b0-d241-4a24-a8fb-619476263e54"})
Mixer_High_Pass :: struct {
	cutoff:    f32 `decor:range(10, 22000)`, // Hz, 5000 when zero
	resonance: f32 `decor:range(0.1, 10)`, // 1 when zero
}

// Turns this group down while the group `by` plays: music under dialogue.
// Above `threshold` the louder `by` is, the more this group is turned down,
// by `ratio`: at 4, 4 dB more of `by` turns this group down 3 dB more.
@(typ_guid={guid = "27afb092-efa9-4e33-9608-62192550247b"})
Mixer_Duck :: struct {
	by:        i64 `inspect:"-"`, // a group of the same mixer, by id
	threshold: f32 `decor:range(-80, 0)`, // dB, -30 when zero
	ratio:     f32 `decor:range(1, 20)`, // 4 when zero
	attack:    f32 `decor:range(1, 5000)`, // ms to turn down, 50 when zero
	release:   f32 `decor:range(1, 5000)`, // ms to come back, 400 when zero
}

MIXER_MASTER_ID :: 1

type_reset_AudioMixer :: proc(m: ^AudioMixer) {
	type_cleanup_AudioMixer(m)
	append(&m.groups, Mixer_Group{id = MIXER_MASTER_ID, name = strings.clone("Master")})
	m.next_id = MIXER_MASTER_ID + 1
}

type_cleanup_AudioMixer :: proc(m: ^AudioMixer) {
	for &g in m.groups {
		delete(g.name)
		delete(g.effects)
	}
	delete(m.groups)
	m^ = {}
}

// A mixer read from a file or edited keeps a Master first, ids unique and
// below next_id, and every parent a group before its child.
type_on_validate_AudioMixer :: proc(m: ^AudioMixer) {
	if len(m.groups) == 0 {
		append(&m.groups, Mixer_Group{id = MIXER_MASTER_ID, name = strings.clone("Master")})
	}
	m.groups[0].parent = 0
	for g in m.groups do m.next_id = max(m.next_id, g.id + 1)
	for &g, i in m.groups {
		for o in m.groups[:i] do if o.id == g.id || g.id <= 0 {
			g.id = m.next_id
			m.next_id += 1
			break
		}
		if i == 0 do continue
		// A parent that is not an earlier group: the Master.
		found := false
		for o in m.groups[:i] do if o.id == g.parent do found = true
		if !found do g.parent = m.groups[0].id
	}
}

// The values a zero field of an effect stands for.
mixer_effect_defaults :: proc(e: Mixer_Effect) -> Mixer_Effect {
	switch v in e {
	case Mixer_Low_Pass:
		return Mixer_Low_Pass{cutoff = v.cutoff > 0 ? v.cutoff : 5000, resonance = v.resonance > 0 ? v.resonance : 1}
	case Mixer_High_Pass:
		return Mixer_High_Pass{cutoff = v.cutoff > 0 ? v.cutoff : 5000, resonance = v.resonance > 0 ? v.resonance : 1}
	case Mixer_Duck:
		return Mixer_Duck{
			by        = v.by,
			threshold = v.threshold < 0 ? v.threshold : -30,
			ratio     = v.ratio >= 1 ? v.ratio : 4,
			attack    = v.attack > 0 ? v.attack : 50,
			release   = v.release > 0 ? v.release : 400,
		}
	}
	return e
}

// The group of id `id`, nil when there is none.
mixer_group :: proc(m: ^AudioMixer, id: i64) -> ^Mixer_Group {
	for &g in m.groups do if g.id == id do return &g
	return nil
}

// Whether `id` is `ancestor` or under it.
mixer_group_is_under :: proc(m: ^AudioMixer, id, ancestor: i64) -> bool {
	at := id
	for _ in 0 ..< len(m.groups) {
		if at == ancestor do return true
		g := mixer_group(m, at)
		if g == nil || g.parent == 0 do return false
		at = g.parent
	}
	return false
}
