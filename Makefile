# SPDX-License-Identifier: GPL-2.0-only

PYTHON ?= python3
NODE ?= node
BUILD_DIR ?= build
SDCARD_DIR := $(BUILD_DIR)/sdcard
VENV_DIR := $(BUILD_DIR)/venv
VENV_STAMP := $(VENV_DIR)/.requirements-installed
DOCS_VENV_DIR := $(BUILD_DIR)/docs-venv
DOCS_VENV_STAMP := $(DOCS_VENV_DIR)/.requirements-installed
CAPTURE_VENV_DIR := $(BUILD_DIR)/capture-venv
CAPTURE_VENV_STAMP := $(CAPTURE_VENV_DIR)/.requirements-installed
VIDEO_VENV_DIR := $(BUILD_DIR)/video-venv
VIDEO_VENV_STAMP := $(VIDEO_VENV_DIR)/.requirements-installed
SIMULATOR_FIXTURE := tests/fixtures/sdcard
WIDGET_SOURCE := src/WIDGETS/AeroGrid
WIDGET_DESTINATION := $(SDCARD_DIR)/WIDGETS/AeroGrid
LUA_FILES := $(shell find src/WIDGETS tests tools/scheduler-audit -type f -name '*.lua' | sort)
LUA_COMPILER ?= $(shell command -v edgetx-luac 2>/dev/null || command -v luac5.3 2>/dev/null || command -v luac 2>/dev/null)
LUACHECK ?= $(shell command -v luacheck 2>/dev/null)
LUA_LS ?= $(shell command -v lua-language-server 2>/dev/null)
STYLUA ?= $(shell command -v stylua 2>/dev/null)
# EdgeTX builds Lua 5.3 with LUA_32BITS (int32 integers, float32 floats). The
# scheduler tests also run on a plain Lua 5.3.6 built that way from lua.org.
LUA32_VERSION := 5.3.6
LUA32_SHA256 := fc5fd69bb8736323f026672b1b7235da613d7177e72558893a0bdcd320466d60
LUA32_DIR := $(BUILD_DIR)/lua32
LUA32 := $(LUA32_DIR)/lua
SCHEDULER_TESTS := $(sort $(wildcard tests/unit/lib/test_scheduler*.lua))

.PHONY: help setup test test-lua32 test-installer check build clean lint format docs docs-serve capture-setup video-setup release-package

help:
	@printf '%s\n' \
	  'make help    List the supported Make targets' \
	  'make setup   Install development dependencies into build/venv' \
	  'make test    Run pure Lua and mocked EdgeTX behavior tests' \
	  'make test-lua32 Run the scheduler tests on a 32-bit-integer Lua 5.3 (EdgeTX build)' \
	  'make test-installer Test browser installer and release mirroring' \
	  'make check   Run behavior tests and syntax validation' \
	  'make lint    Lint Lua files with lua-language-server' \
	  'make format  Format Lua files with stylua' \
	  'make build   Recreate build/sdcard from fixture and widget sources' \
	  'make docs    Build and validate the documentation website' \
	  'make docs-serve Preview documentation at http://127.0.0.1:8000' \
	  'make capture-setup Install optional screenshot dependencies' \
	  'make video-setup Install optional tutorial video dependencies' \
	  'make release-package Build the source-only installation ZIP and checksum' \
	  'make clean   Remove generated build output'

setup: $(VENV_STAMP)

release-package:
	@"$(PYTHON)" tools/package-release.py --output "$(BUILD_DIR)/release"

capture-setup: $(CAPTURE_VENV_STAMP)

video-setup: $(VIDEO_VENV_STAMP)

$(VIDEO_VENV_STAMP): requirements-video.txt
	@mkdir -p "$(BUILD_DIR)"
	@test -x "$(VIDEO_VENV_DIR)/bin/python" || "$(PYTHON)" -m venv "$(VIDEO_VENV_DIR)"
	@"$(VIDEO_VENV_DIR)/bin/python" -m pip install -r requirements-video.txt
	@touch "$@"

$(CAPTURE_VENV_STAMP): requirements-capture.txt
	@mkdir -p "$(BUILD_DIR)"
	@test -x "$(CAPTURE_VENV_DIR)/bin/python" || "$(PYTHON)" -m venv "$(CAPTURE_VENV_DIR)"
	@"$(CAPTURE_VENV_DIR)/bin/python" -m pip install -r requirements-capture.txt
	@touch "$@"

$(DOCS_VENV_STAMP): requirements-docs.txt
	@mkdir -p "$(BUILD_DIR)"
	@test -x "$(DOCS_VENV_DIR)/bin/python" || "$(PYTHON)" -m venv "$(DOCS_VENV_DIR)"
	@"$(DOCS_VENV_DIR)/bin/python" -m pip install -r requirements-docs.txt
	@touch "$@"

docs: $(DOCS_VENV_STAMP)
	@"$(DOCS_VENV_DIR)/bin/python" -m mkdocs build --strict --site-dir "$(BUILD_DIR)/docs"

docs-serve: $(DOCS_VENV_STAMP)
	@"$(DOCS_VENV_DIR)/bin/python" -m mkdocs serve --strict

$(VENV_STAMP): requirements-dev.txt
	@mkdir -p "$(BUILD_DIR)"
	@test -x "$(VENV_DIR)/bin/python" || "$(PYTHON)" -m venv "$(VENV_DIR)"
	@"$(VENV_DIR)/bin/python" -m pip install -r requirements-dev.txt
	@touch "$@"

test: $(VENV_STAMP)
	@"$(VENV_DIR)/bin/python" -m unittest discover -s tests -p 'test_*.py'
	@"$(VENV_DIR)/bin/python" tests/run.py

$(LUA32):
	@mkdir -p "$(LUA32_DIR)"
	@curl -fsSL -o "$(LUA32_DIR)/lua.tar.gz" "https://www.lua.org/ftp/lua-$(LUA32_VERSION).tar.gz"
	@"$(PYTHON)" -c "import hashlib,sys; sys.exit(0 if hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest()==sys.argv[2] else 'Lua source checksum mismatch')" "$(LUA32_DIR)/lua.tar.gz" "$(LUA32_SHA256)"
	@tar -xzf "$(LUA32_DIR)/lua.tar.gz" --strip-components=1 -C "$(LUA32_DIR)"
	@$(MAKE) -C "$(LUA32_DIR)/src" generic MYCFLAGS=-DLUA_32BITS >/dev/null
	@cp "$(LUA32_DIR)/src/lua" "$@"
	@"$@" -e "assert(math.maxinteger == 2147483647 and string.packsize('n') == 4)"

test-lua32: $(LUA32)
	@for file in $(SCHEDULER_TESTS); do "$(LUA32)" "$$file" "$(CURDIR)" || exit 1; done

test-installer:
	@"$(PYTHON)" -m unittest discover -s tools -p 'test_installer_*.py'
	@"$(NODE)" --test tests/browser/*.test.mjs

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
	if lua-language-server --check src/WIDGETS tests --configpath="$(CURDIR)/lint-config.lua"; then \
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
	@rsync -a "tests/fixtures/layouts/development/" "$(WIDGET_DESTINATION)/layouts/"
# EdgeTX compiles each script to .luac beside it and prefers the bytecode.
# rsync preserves source timestamps, so a freshly copied .lua can look older
# than bytecode the radio compiled from the previous build, and the radio then
# keeps running code that is no longer on disk. Drop the bytecode and stamp the
# sources as new so the radio always recompiles what was just built.
	@find "$(SDCARD_DIR)" -name '*.luac' -delete
	@find "$(SDCARD_DIR)" -name '*.lua' -exec touch {} +
	@printf 'Built simulator SD image at %s\n' "$(SDCARD_DIR)"

clean:
	@rm -rf "$(BUILD_DIR)"