# Convenience wrappers around run.sh / run_debug.sh / run_tests.sh /
# run_mcp_shim.sh. `odin build` refuses an extension-less -out path on
# Windows, so EDITOR_BIN/MCP_BIN carry .exe there; the *nix scripts don't
# need it, so this also works unchanged on macOS/Linux.

COLLECTION   := -collection:moonhug=moonhug
IGNORE_ATTRS := -ignore-unknown-attributes

ifeq ($(OS),Windows_NT)
EXE := .exe
else
EXE :=
endif

EDITOR_BIN := builds/MoonHug$(EXE)
MCP_BIN    := builds/mcp_shim$(EXE)

# make test NAME=tests.some_test_name  -> odin's package.test_name filter
NAME ?=
TEST_FILTER := $(if $(NAME),-define:ODIN_TEST_NAMES=$(NAME),)

.PHONY: help run debug build build-debug prebuild shaders app app-debug test mcp clean distclean

help:
	@echo "make run                    build (release) + launch the editor"
	@echo "make debug                  build (-debug) + launch the editor"
	@echo "make build                  build the editor only, don't launch it"
	@echo "make build-debug            build the editor (-debug) only, don't launch it"
	@echo "make prebuild               codegen only: prune stale gens + run prebuild"
	@echo "make shaders                recompile built-in GLSL shaders (needs glslc + spirv-cross)"
	@echo "make app                    build + run the game (packages/app, release run config)"
	@echo "make app-debug              build + run the game (packages/app, debug run config)"
	@echo "make test                   run the full test suite"
	@echo "make test NAME=pkg.test     run one test (odin's package.test_name filter)"
	@echo "make mcp                    build + run the MCP stdio shim"
	@echo "make clean                  remove builds/ (gitignored build output)"
	@echo "make distclean              also remove moonhug/library/ (derived cache; safe, rebuilds on next run)"

prebuild:
	odin run moonhug/prebuild/prune_package_gens
	odin run moonhug/prebuild $(COLLECTION)

shaders:
	sh moonhug/engine/gfx/shaders/compile.sh

build: prebuild
	@mkdir -p builds
	@if command -v glslc >/dev/null 2>&1 && command -v spirv-cross >/dev/null 2>&1; then \
		sh moonhug/engine/gfx/shaders/compile.sh; \
	fi
	odin build moonhug/editor $(IGNORE_ATTRS) $(COLLECTION) -out:$(EDITOR_BIN)

build-debug: prebuild
	@mkdir -p builds
	odin build moonhug/editor $(IGNORE_ATTRS) $(COLLECTION) -debug -out:$(EDITOR_BIN)

run: build
	./$(EDITOR_BIN)

debug: build-debug
	./$(EDITOR_BIN)

app: prebuild
	odin run moonhug/packages/app/run_configs/run.odin -file $(COLLECTION)

app-debug: prebuild
	odin run moonhug/packages/app/run_configs/run_debug.odin -file $(COLLECTION)

test:
	odin test moonhug/tests -all-packages $(IGNORE_ATTRS) $(COLLECTION) -define:ODIN_TEST_THREADS=1 $(TEST_FILTER)

mcp:
	@mkdir -p builds
	odin build moonhug/mcp_shim $(COLLECTION) -out:$(MCP_BIN) -o:minimal
	./$(MCP_BIN)

clean:
	rm -rf builds

distclean: clean
	rm -rf moonhug/library
