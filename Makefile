
export PJ_ROOT=$(PWD)

FILTER ?= .*

export NVIM_RUNNER_VERSION := v0.10.0
export NVIM_TEST_VERSION ?= v0.10.0

ifeq ($(shell uname -s),Darwin)
    UNAME ?= MACOS
else
    UNAME ?= LINUX
endif

.DEFAULT_GOAL := test

nvim-test:
	git clone https://github.com/lewis6991/nvim-test
	nvim-test/bin/nvim-test --init

.PHONY: test
test: nvim-test
	NVIM_TEST_VERSION=$(NVIM_TEST_VERSION) \
	nvim-test/bin/nvim-test test \
		--lpath=$(PWD)/lua/?.lua \
		--verbose \
		--filter="$(FILTER)"

	-@stty sane

export XDG_DATA_HOME ?= $(HOME)/.data

STYLUA_PLATFORM_MACOS := macos-aarch64
STYLUA_PLATFORM_LINUX := linux-x86_64
STYLUA_PLATFORM := $(STYLUA_PLATFORM_$(UNAME))

STYLUA_VERSION := v0.20.0
STYLUA_ZIP := stylua-$(STYLUA_PLATFORM).zip
STYLUA_URL_BASE := https://github.com/JohnnyMorganz/StyLua/releases/download
STYLUA_URL := $(STYLUA_URL_BASE)/$(STYLUA_VERSION)/$(STYLUA_ZIP)

.INTERMEDIATE: $(STYLUA_ZIP)
$(STYLUA_ZIP):
	wget $(STYLUA_URL)

stylua: $(STYLUA_ZIP)
	unzip $<

FILES = lua/*.lua test/*.lua

.PHONY: format-check
format-check: stylua
	./stylua --check $(FILES)

.PHONY: format
format: stylua
	./stylua $(FILES)

LUALS_VERSION := 3.9.3
LUALS_TARBALL := lua-language-server-$(LUALS_VERSION)-$(shell uname -s)-$(shell uname -m).tar.gz
LUALS_URL := https://github.com/LuaLS/lua-language-server/releases/download/$(LUALS_VERSION)/$(LUALS_TARBALL)

luals:
	wget $(LUALS_URL)
	mkdir luals
	tar -xf $(LUALS_TARBALL) -C luals
	rm -rf $(LUALS_TARBALL)

.PHONY: luals-check
luals-check: luals nvim-test
	VIMRUNTIME=$(XDG_DATA_HOME)/nvim-test/nvim-test-$(NVIM_TEST_VERSION)/share/nvim/runtime \
		luals/bin/lua-language-server \
			--logpath=. \
			--configpath=../.luarc.json \
			--check=lua
