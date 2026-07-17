#+build !darwin
package editor

// Non-macOS stubs; see project_os_darwin.odin. Windows would use
// SHFileOperation/IFileOperation for the recycle bin and
// `explorer /select` for reveal.

import "core:fmt"

file_move_to_trash :: proc(path: string) -> bool {
	fmt.printf("[Editor] Move to trash: not implemented on this OS (%s)\n", path)
	return false
}

file_reveal_in_os :: proc(path: string) -> bool {
	fmt.printf("[Editor] Show in file manager: not implemented on this OS (%s)\n", path)
	return false
}
