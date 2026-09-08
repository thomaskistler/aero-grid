# SPDX-License-Identifier: GPL-2.0-only

PYTHON ?= python3
BUILD_DIR ?= build
SDCARD_DIR := $(BUILD_DIR)/sdcard
VENV_DIR := $(BUILD_DIR)/venv
VENV_STAMP := $(VENV_DIR)/.requirements-installed
SIMULATOR_FIXTURE := simulator/sdcard
WIDGET_SOURCE := WIDGETS/AeroGrid
WIDGET_DESTINATION := $(SDCARD_DIR)/WIDGETS/AeroGrid
LUA_FILES := $(shell find WIDGETS tests -type f -name '*.lua' | sort)
LUA_COMPILER ?= $(shell command -v edgetx-luac 2>/dev/null || command -v luac5.3 2>/dev/null || command -v luac 2>/dev/null)

.PHONY: help setup test check build clean

help:
	@printf '%s\n' \
	  'make setup   Install development dependencies into build/venv' \
	  'make test    Run pure Lua and mocked EdgeTX behavior tests' \
	  'make check   Run behavior tests and syntax validation' \
	  'make build   Recreate build/sdcard from fixture and widget sources' \
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

build:
	@mkdir -p "$(SDCARD_DIR)"
	@rsync -a --delete "$(SIMULATOR_FIXTURE)/" "$(SDCARD_DIR)/"
	@mkdir -p "$(dir $(WIDGET_DESTINATION))"
	@rsync -a --delete "$(WIDGET_SOURCE)/" "$(WIDGET_DESTINATION)/"
	@printf 'Built simulator SD image at %s\n' "$(SDCARD_DIR)"

clean:
	@rm -rf "$(BUILD_DIR)"