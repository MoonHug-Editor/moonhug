#!/bin/sh
# MCP stdio entry point (registered in .mcp.json): builds the shim if needed
# and execs it. Build output is quiet so stdout stays a clean JSON-RPC stream.
cd "$(dirname "$0")" || exit 1
mkdir -p builds
odin build moonhug/mcp_shim -collection:moonhug=moonhug -out:builds/mcp_shim -o:minimal 1>&2 || exit 1
exec ./builds/mcp_shim
