package editor_tests

// The editor's one text search (widgets/search.odin): every word of a query
// must appear in a candidate, case ignored, and spaces, underscores and
// hyphens never decide a match.

import "core:testing"
import "moonhug:editor/widgets"

@(test)
test_search_ignores_spaces_underscores_and_hyphens :: proc(t: ^testing.T) {
	finds :: proc(query, name: string) -> bool {
		return widgets.search_match(name, widgets.search_terms(query))
	}
	for name in ([]string{"PlayerController", "Player_Controller", "player-controller", "Player Controller"}) {
		testing.expectf(t, finds("playercontroller", name), "playercontroller finds %q", name)
		testing.expectf(t, finds("player_con", name), "player_con finds %q", name)
		testing.expectf(t, finds("Player-Controller", name), "Player-Controller finds %q", name)
		testing.expectf(t, finds("cont play", name), "words in any order find %q", name)
	}
	testing.expect(t, !finds("player_enemy", "Player_Controller"), "every word must appear")
	testing.expect(t, finds("", "anything"), "an empty query finds everything")
	testing.expect(t, finds("_", "anything"), "a word of separators only is no word")

	// A tagged word folds the same way.
	plain, tagged := widgets.search_split(widgets.search_terms("c:sprite_renderer$"))
	testing.expect_value(t, len(plain), 0)
	word, exact, ok := widgets.search_tag(tagged[0], "c:")
	testing.expect(t, ok && exact, "c: with $ is an exact tag")
	testing.expect(t, widgets.search_tag_match("SpriteRenderer", word, exact), "sprite_renderer$ is SpriteRenderer")
	testing.expect(t, !widgets.search_tag_match("SpriteRendererExtra", word, exact), "and only it")
}
