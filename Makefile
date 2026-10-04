# Shortcuts for tools/mh. This file FORWARDS ONLY — every build decision lives
# in tools/mh, so there is one definition of how this repo builds and nothing
# here can drift from it.
#
# make is optional. Without it, run the same commands directly:
#
#   odin run tools/mh -- <command>
#
# make test NAME=pkg.test_name runs a single test. make deps NAME=<plugin>
# gathers one plugin's dependencies.

# mh itself is compiled once into builds/tools/ and rebuilt when its sources
# change (Odin has no build cache, `odin run` recompiled it on every make).
MH_BIN := builds/tools/mh
MH := $(MH_BIN)

$(MH_BIN): $(wildcard tools/mh/*.odin)
	@mkdir -p builds/tools && odin build tools/mh -out:$@

.PHONY: help setup run debug build app test prebuild deps shaders docs mcp clean distclean

help:      $(MH_BIN) ; @$(MH) help
setup:     $(MH_BIN) ; @$(MH) setup
run:       $(MH_BIN) ; @$(MH) run
debug:     $(MH_BIN) ; @$(MH) debug
build:     $(MH_BIN) ; @$(MH) build
app:       $(MH_BIN) ; @$(MH) app
prebuild:  $(MH_BIN) ; @$(MH) prebuild
deps:      $(MH_BIN) ; @$(MH) deps $(NAME)
shaders:   $(MH_BIN) ; @$(MH) shaders
# make cannot take --open itself, so `make docs OPEN=1` serves and opens.
docs:      $(MH_BIN) ; @$(MH) docs $(if $(OPEN),--open,)
mcp:       $(MH_BIN) ; @$(MH) mcp
clean:     $(MH_BIN) ; @$(MH) clean
distclean: $(MH_BIN) ; @$(MH) clean --all
test:      $(MH_BIN) ; @$(MH) test $(if $(NAME),--name=$(NAME),)
