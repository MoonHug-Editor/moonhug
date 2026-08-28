# Shortcuts for tools/mh. This file FORWARDS ONLY — every build decision lives
# in tools/mh, so there is one definition of how this repo builds and nothing
# here can drift from it.
#
# make is optional. Without it, run the same commands directly:
#
#   odin run tools/mh -- <command>
#
# make test NAME=pkg.test_name runs a single test.

MH := odin run tools/mh --

.PHONY: help setup run debug build app test prebuild shaders mcp clean distclean

help:      ; @$(MH) help
setup:     ; @$(MH) setup
run:       ; @$(MH) run
debug:     ; @$(MH) debug
build:     ; @$(MH) build
app:       ; @$(MH) app
prebuild:  ; @$(MH) prebuild
shaders:   ; @$(MH) shaders
mcp:       ; @$(MH) mcp
clean:     ; @$(MH) clean
distclean: ; @$(MH) clean --all
test:      ; @$(MH) test $(if $(NAME),--name=$(NAME),)
