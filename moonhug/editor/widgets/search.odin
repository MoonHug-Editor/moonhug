package widgets

// The one text search every filter and picker in the editor uses. A query is
// words separated by spaces, and a candidate matches when every word appears
// in it, case-insensitively: "track aud" finds "Sequencer/Tracks/TrackAudio".
// Split the query once per frame with search_terms, then ask search_match
// per candidate.

import "core:strings"

// The query's words, lowercased. Temp-allocated. Empty for an empty query,
// which matches everything.
search_terms :: proc(query: string) -> []string {
	words := strings.fields(query, context.temp_allocator)
	for &w in words do w = strings.to_lower(w, context.temp_allocator)
	return words
}

search_match :: proc(text: string, terms: []string) -> bool {
	if len(terms) == 0 do return true
	lower := strings.to_lower(text, context.temp_allocator)
	for t in terms do if !strings.contains(lower, t) do return false
	return true
}
