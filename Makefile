# Shortcuts for tools/mh. This file FORWARDS ONLY — every build decision lives
# in tools/mh, so there is one definition of how this repo builds and nothing
# here can drift from it.
#
# make is optional. Without it, run the same commands directly:
#
#   odin run tools/mh -- <command>
#
# make play PKG=app:run FLAGS=--build-only runs a run configuration (PKG defaults to the one package shipping them).
# make test NAME=pkg.test_name runs a single test. make deps NAME=<plugin>
# gathers one plugin's dependencies. make build DEBUG=1 builds with -debug,
# make setup FORCE=1 rebuilds vendored libraries that are already built.
# make build PROF=zones (or all) builds with the Tracy profiler, also for run
# and debug (docs/core/Profiling.md).

# mh itself is compiled once into builds/tools/ and rebuilt when its sources
# change (Odin has no build cache, `odin run` recompiled it on every make), or
# when the Odin installation changes: ODIN_STAMP holds `odin root` and is
# rewritten only when that differs, so an upgrade rebuilds mh and mh rebuilds
# its tools (tools/mh/tools_cache.odin).
MH_BIN := builds/tools/mh
MH := $(MH_BIN)
ODIN_STAMP := builds/tools/.odin-root

# Checked when make reads this file, not as a target: make 3.81, the one macOS
# ships, takes a target with a FORCE prerequisite as changed even when its
# file was not rewritten, which rebuilt mh on every make.
ODIN_ROOT := $(shell odin root)
ifneq ($(ODIN_ROOT),$(shell cat $(ODIN_STAMP) 2>/dev/null))
$(shell mkdir -p builds/tools && odin root > $(ODIN_STAMP))
endif

$(MH_BIN): $(wildcard tools/mh/*.odin) $(ODIN_STAMP)
	@mkdir -p builds/tools && odin build tools/mh -out:$@


.PHONY: help setup run debug build check-noplugins play test scenarios prebuild deps shaders docs mcp clean distclean

help:      $(MH_BIN) ; @$(MH) help
setup:     $(MH_BIN) ; @$(MH) setup $(if $(FORCE),--force,)
run:       $(MH_BIN) ; @$(MH) run $(if $(PROF),--prof=$(PROF),) $(if $(OPT),--opt=$(OPT),)
debug:     $(MH_BIN) ; @$(MH) debug $(if $(PROF),--prof=$(PROF),) $(if $(OPT),--opt=$(OPT),)
build:     $(MH_BIN) ; @$(MH) build $(if $(DEBUG),--debug,) $(if $(NOPLUGINS),--no-plugins,) $(if $(PROF),--prof=$(PROF),) $(if $(OPT),--opt=$(OPT),)
check-noplugins: $(MH_BIN) ; @$(MH) check-noplugins
play:      $(MH_BIN) ; @$(MH) play $(PKG) $(FLAGS) $(if $(OPT),--opt=$(OPT),)
prebuild:  $(MH_BIN) ; @$(MH) prebuild
deps:      $(MH_BIN) ; @$(MH) deps $(NAME)
shaders:   $(MH_BIN) ; @$(MH) shaders
# make cannot take --open itself, so `make docs OPEN=1` serves and opens.
docs:      $(MH_BIN) ; @$(MH) docs $(if $(OPEN),--open,)
mcp:       $(MH_BIN) ; @$(MH) mcp
clean:     $(MH_BIN) ; @$(MH) clean
distclean: $(MH_BIN) ; @$(MH) clean --all
test:      $(MH_BIN) ; @$(MH) test $(if $(NAME),--name=$(NAME),)
test-asan: $(MH_BIN) ; @$(MH) test-asan $(if $(NAME),--name=$(NAME),)
# make scenarios NAME=<test> runs one scenario, SHOW=1 gives the editor a
# window on screen.
scenarios: $(MH_BIN) ; @$(MH) scenarios $(if $(NAME),--name=$(NAME),) $(if $(SHOW),--show,)
