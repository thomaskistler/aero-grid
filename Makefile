# SPDX-License-Identifier: GPL-2.0-only

PYTHON ?= python3
BUILD_DIR ?= build
SDCARD_DIR := $(BUILD_DIR)/sdcard
VENV_DIR := $(BUILD_DIR)/venv
VENV_STAMP := $(VENV_DIR)/.requirements-installed
SIMULATOR_FIXTURE := tests/fixtures/sdcard
WIDGET_SOURCE := src/WIDGETS/AeroGrid
WIDGET_DESTINATION := $(SDCARD_DIR)/WIDGETS/AeroGrid
LUA_FILES := $(shell find src/WIDGETS tests -type f -name '*.lua' | sort)
LUA_COMPILER ?= $(shell command -v edgetx-luac 2>/dev/null || command -v luac5.3 2>/dev/null || command -v luac 2>/dev/null)
LUACHECK ?= $(shell command -v luacheck 2>/dev/null)
LUA_LS ?= $(shell command -v lua-language-server 2>/dev/null)
STYLUA ?= $(shell command -v stylua 2>/dev/null)

.PHONY: help setup test check build mocks clean lint format

help:
	@printf '%s\n' \
	  'make help    List the supported Make targets' \
	  'make setup   Install development dependencies into build/venv' \
	  'make test    Run pure Lua and mocked EdgeTX behavior tests' \
	  'make check   Run behavior tests and syntax validation' \
	  'make lint    Lint Lua files with lua-language-server' \
	  'make format  Format Lua files with stylua' \
	  'make build   Recreate build/sdcard from fixture and widget sources' \
	  'make mocks   Render build/flow-mocks.html from the real panel geometry' \
	  'make clean   Remove generated build output'

setup: $(VENV_STAMP)

$(VENV_STAMP): requirements-dev.txt
	@mkdir -p "$(BUILD_DIR)"
	@test -x "$(VENV_DIR)/bin/python" || "$(PYTHON)" -m venv "$(VENV_DIR)"
	@"$(VENV_DIR)/bin/python" -m pip install -r requirements-dev.txt
	@touch "$@"

test: $(VENV_STAMP)
	@"$(VENV_DIR)/bin/python" tests/run.py

check: test
	@test -n "$(LUA_COMPILER)" || { \
	  printf '%s\n' 'error: install edgetx-luac or Lua 5.3 luac, or set LUA_COMPILER=/path/to/compiler'; \
	  exit 1; \
	}
	@for file in $(LUA_FILES); do \
	  "$(LUA_COMPILER)" -p "$$file"; \
	done

lint:
	@test -n "$(LUA_LS)" || { \
	  printf '%s\n' 'error: lua-language-server not found. Install with: luarocks install lua-language-server'; \
	  exit 1; \
	}
	@echo "Linting Lua files with lua-language-server..."; \
	if lua-language-server --check src/WIDGETS tests; then \
	  echo "All Lua files passed linting"; \
	else \
	  echo "Lua language server linting failed"; \
	  exit 1; \
	fi

format:
	@test -n "$(STYLUA)" || { \
	  printf '%s\n' 'error: stylua not found. Install with: luarocks install stylua'; \
	  exit 1; \
	}
	@stylua --indent-type Spaces $(LUA_FILES)

build:
	@mkdir -p "$(SDCARD_DIR)"
	@rsync -a --delete "$(SIMULATOR_FIXTURE)/" "$(SDCARD_DIR)/"
	@mkdir -p "$(dir $(WIDGET_DESTINATION))"
	@rsync -a --delete "$(WIDGET_SOURCE)/" "$(WIDGET_DESTINATION)/"
# EdgeTX compiles each script to .luac beside it and prefers the bytecode.
# rsync preserves source timestamps, so a freshly copied .lua can look older
# than bytecode the radio compiled from the previous build, and the radio then
# keeps running code that is no longer on disk. Drop the bytecode and stamp the
# sources as new so the radio always recompiles what was just built.
	@find "$(SDCARD_DIR)" -name '*.luac' -delete
	@find "$(SDCARD_DIR)" -name '*.lua' -exec touch {} +
	@printf 'Built simulator SD image at %s\n' "$(SDCARD_DIR)"

# Design mocks. Builds every panel through the real host, walks the geometry
# back out of the LVGL mock, and renders it beside a proposed arrangement. The
# page is an artefact for looking at, not a test, so nothing depends on it.
mocks: $(VENV_STAMP)
	@mkdir -p "$(BUILD_DIR)"
	@"$(VENV_DIR)/bin/python" -c "import sys;from pathlib import Path;\
	from lupa import LuaRuntime;l=LuaRuntime(unpack_returned_tuples=True);\
	l.execute(Path('tools/flow-geometry.lua').read_text(), str(Path('.').resolve()))" \
	  > "$(BUILD_DIR)/flow-cases.lua"
	@"$(VENV_DIR)/bin/python" tools/flow-render.py

clean:
	@rm -rf "$(BUILD_DIR)"