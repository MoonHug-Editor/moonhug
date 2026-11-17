package widgets

// The one text search every filter and picker in the editor uses. A query is
// words separated by spaces, and a candidate matches when every word appears
// in it, case-insensitively: "track aud" finds "Sequencer/Tracks/TrackAudio".
// Spaces, underscores and hyphens split words differently from name to name,
// so both sides are compared without them (search_fold): "playercontroller"
// finds "Player_Controller" and "Player Controller", "player_con" finds
// "PlayerController". Split the query once per frame with search_terms, then
// ask search_match per candidate.

import "core:strings"
import "core:unicode"

// The query's words, folded (search_fold). Temp-allocated. Empty for an
// empty query, which matches everything.
search_terms :: proc(query: string) -> []string {
	words := strings.fields(query, context.temp_allocator)
	for &w in words do w = search_fold(w)
	return words
}

search_match :: proc(text: string, terms: []string) -> bool {
	if len(terms) == 0 do return true
	folded := search_fold(text)
	for t in terms do if !strings.contains(folded, t) do return false
	return true
}

// Text as a search compares it: lowercase, without spaces, underscores and
// hyphens. Temp-allocated.
search_fold :: proc(text: string) -> string {
	b := strings.builder_make(0, len(text), context.temp_allocator)
	for r in text {
		switch r {
		case ' ', '_', '-':
		case:
			strings.write_rune(&b, unicode.to_lower(r))
		}
	}
	return strings.to_string(b)
}

// A filter word with a tag: "c:sprite" under the tag "c:" is the word
// "sprite". A "$" at its end marks the end of the name it is matched with:
// "c:sprite$" is the whole name, exact. Terms come from search_terms, so
// they are lowercase. `ok` is false for a term without the tag.
search_tag :: proc(term, tag: string) -> (word: string, exact: bool, ok: bool) {
	if !strings.has_prefix(term, tag) do return
	word = term[len(tag):]
	exact = strings.has_suffix(word, "$")
	if exact do word = word[:len(word) - 1]
	return word, exact, true
}

// Whether `name` matches a tagged word: the whole name when `exact`, else any
// part of it. Folded as search_match is, `word` already folded.
search_tag_match :: proc(name, word: string, exact: bool) -> bool {
	folded := search_fold(name)
	return exact ? folded == word : strings.contains(folded, word)
}

// The query's terms in two lists: the tagged ones ("c:light", "t:mat$": one
// letter and a colon) and the plain ones, which match a name. Every search
// that takes tagged words splits its terms here, so they all agree on what a
// tag is. Temp-allocated.
search_split :: proc(terms: []string) -> (plain: []string, tagged: []string) {
	p := make([dynamic]string, 0, len(terms), context.temp_allocator)
	t := make([dynamic]string, 0, len(terms), context.temp_allocator)
	for term in terms {
		if len(term) >= 2 && term[1] == ':' && term[0] >= 'a' && term[0] <= 'z' {
			append(&t, term)
		} else {
			append(&p, term)
		}
	}
	return p[:], t[:]
}
