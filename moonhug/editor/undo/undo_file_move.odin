package undo

// The undo command of files and folders moved or renamed in the Project
// window: a move back is a move, so each direction renames every item, its
// .meta with it, and the item keeps its id.
//
// The stack does not know the Project window. After either direction it
// calls file_moves_applied with where each item is now, and the editor
// refreshes what it shows.

import "core:fmt"
import "core:os"
import "core:strings"
import "moonhug:libs/log"

// One item's move. The strings are the command's own.
File_Move :: struct {
	from: string,
	to:   string,
}

@(undo_command)
File_Move_Command :: struct {
	moves: [dynamic]File_Move,
	label: string, // a literal
}

// Set by the editor: the files of a move just went one way or the other.
// Each pair is (where it was, where it is now).
file_moves_applied: proc(done: [][2]string)

// The command for moves already made: (from, to) pairs, cloned.
file_move_command :: proc(pairs: [][2]string, label: string) -> File_Move_Command {
	cmd := File_Move_Command{label = label}
	for p in pairs do append(&cmd.moves, File_Move{from = strings.clone(p[0]), to = strings.clone(p[1])})
	return cmd
}

apply_File_Move_Command :: proc(v: ^File_Move_Command) {
	done := make([dynamic][2]string, context.temp_allocator)
	for m in v.moves do if _file_move(m.from, m.to) do append(&done, [2]string{m.from, m.to})
	if file_moves_applied != nil do file_moves_applied(done[:])
}

revert_File_Move_Command :: proc(v: ^File_Move_Command) {
	done := make([dynamic][2]string, context.temp_allocator)
	// Backwards: a folder moved after a file inside it goes back first.
	#reverse for m in v.moves do if _file_move(m.to, m.from) do append(&done, [2]string{m.to, m.from})
	if file_moves_applied != nil do file_moves_applied(done[:])
}

// Moves one item with its .meta. An item that is gone, or a place that is
// taken, is left alone with a line in the Console.
@(private = "file")
_file_move :: proc(from, to: string) -> bool {
	if !os.exists(from) {
		log.warning(fmt.tprintf("Undo: %s is not there any more, it stays as it is", from))
		return false
	}
	if os.exists(to) {
		log.warning(fmt.tprintf("Undo: %s is taken, %s stays where it is", to, from))
		return false
	}
	if err := os.rename(from, to); err != nil {
		log.warning(fmt.tprintf("Undo: moving %s to %s failed: %v", from, to, err))
		return false
	}
	meta := strings.concatenate({from, ".meta"}, context.temp_allocator)
	if os.exists(meta) do os.rename(meta, strings.concatenate({to, ".meta"}, context.temp_allocator))
	return true
}

destroy_File_Move_Command :: proc(v: ^File_Move_Command) {
	for m in v.moves {
		delete(m.from)
		delete(m.to)
	}
	delete(v.moves)
}

label_File_Move_Command :: proc(v: ^File_Move_Command) -> string {
	return v.label
}

describe_File_Move_Command :: proc(v: ^File_Move_Command, b: ^strings.Builder, depth: int) {
	fmt.sbprintf(b, "%s%s\n", _indent(depth), v.label)
	for m in v.moves do fmt.sbprintf(b, "%s%s -> %s\n", _indent(depth + 1), m.from, m.to)
}
