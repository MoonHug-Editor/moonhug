package mcp

// The bridge's on/off switch, a project settings tab. The bridge reads it at
// editor start (editor/mcp_bridge.odin).

// A single on/off switch for the whole endpoint (docs/core/McpBridge.md). Off
// means the editor does not listen at all, so no agent can reach the editor by
// any tool, enforceable with no per-tool knowledge.
// There is deliberately no read/write split: a per-tool "does this mutate"
// flag would be hand-classified, and a mislabeled tool would sneak past it.
// Every tool mutation goes through the editor's undo stack, so agent edits are
// Ctrl+Z-able like manual ones.
Mcp_Settings :: struct {
	enabled: bool `decor:tooltip(desc="Let agent clients (Claude Code and other MCP clients) connect to this editor over a loopback socket: read scene state, take screenshots, and make undoable edits. Off stops the editor listening entirely. Takes effect on editor restart.")`,
}

@(project_settings={name="MCP"})
mcp_settings := Mcp_Settings{enabled = true}
