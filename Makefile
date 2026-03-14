
export PJ_ROOT=$(PWD)

FILTER ?= .*

export NVIM_RUNNER_VERSION := v0.11.0
export NVIM_TEST_VERSION ?= v0.11.0

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

STYLUA_VERSION := v2.4.0
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

EMMYLUA_REF := 0.21.0
EMMYLUA_OS ?= $(shell uname -s | tr '[:upper:]' '[:lower:]')
ifneq ($(filter $(shell uname -m),x86_64 amd64),)
  EMMYLUA_ARCH := x64
else
  EMMYLUA_ARCH := arm64
endif
EMMYLUA_RELEASE_URL := https://github.com/EmmyLuaLs/emmylua-analyzer-rust/releases/download/$(EMMYLUA_REF)/emmylua_check-$(EMMYLUA_OS)-$(EMMYLUA_ARCH).tar.gz
EMMYLUA_RELEASE_TAR := deps/emmylua_check-$(EMMYLUA_REF)-$(EMMYLUA_OS)-$(EMMYLUA_ARCH).tar.gz
EMMYLUA_DIR := deps/emmylua
EMMYLUA_BIN := $(EMMYLUA_DIR)/emmylua_check

.PHONY: emmylua
emmylua: $(EMMYLUA_BIN)

ifeq ($(shell echo $(EMMYLUA_REF) | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$$'),$(EMMYLUA_REF))

$(EMMYLUA_BIN):
	mkdir -p $(EMMYLUA_DIR)
	curl -L $(EMMYLUA_RELEASE_URL) -o $(EMMYLUA_RELEASE_TAR)
	tar -xzf $(EMMYLUA_RELEASE_TAR) -C $(EMMYLUA_DIR)

else

$(EMMYLUA_BIN):
	git clone --filter=blob:none https://github.com/EmmyLuaLs/emmylua-analyzer-rust.git $(EMMYLUA_DIR)
	git -C $(EMMYLUA_DIR) checkout $(EMMYLUA_SHA)
	cd $(EMMYLUA_DIR) && cargo build --release --package emmylua_check

endif

.PHONY: emmylua-check
emmylua-check: $(EMMYLUA_BIN)
	$(EMMYLUA_BIN) lua \
		--config .emmyrc.json

.PHONY: doc
doc:
	emmylua_doc_cli \
		--input lua \
		--output . \
		--format=json
	./docgen.lua doc.json doc/lua-async.txt
