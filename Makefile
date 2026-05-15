PREFIX ?= /usr/local
BIN_DIR := $(PREFIX)/bin
BINARY := mindofagent
SOURCE_BINARY := .build/release/MindOfAgent

LAUNCH_AGENT_LABEL := io.stevedores.mindofagent
LAUNCH_AGENT_DIR := $(HOME)/Library/LaunchAgents
LAUNCH_AGENT_PLIST := $(LAUNCH_AGENT_DIR)/$(LAUNCH_AGENT_LABEL).plist
PLIST_TEMPLATE := deployment/macos/$(LAUNCH_AGENT_LABEL).plist.template

.PHONY: help build build-release test install-binary install-launch-agent uninstall-launch-agent clean

help:
	@echo "MindOfAgent — make targets"
	@echo ""
	@echo "  make build                  swift build (debug)"
	@echo "  make build-release          swift build -c release"
	@echo "  make test                   swift test (requires Xcode for XCTest)"
	@echo "  make install-launch-agent   build release, install binary, install LaunchAgent, start it"
	@echo "  make uninstall-launch-agent stop and remove the LaunchAgent (binary stays)"
	@echo "  make clean                  rm -rf .build"

build:
	swift build

build-release:
	swift build -c release

test:
	swift test

# Install the release binary into PREFIX/bin. Falls back to sudo when the
# directory isn't writable (the default /usr/local/bin on a stock Mac).
install-binary: build-release
	@if [ ! -w "$(BIN_DIR)" ] && [ -d "$(BIN_DIR)" ]; then \
		echo "==> Installing $(BINARY) to $(BIN_DIR) (requires sudo)"; \
		sudo install -m 0755 $(SOURCE_BINARY) $(BIN_DIR)/$(BINARY); \
	else \
		mkdir -p $(BIN_DIR); \
		install -m 0755 $(SOURCE_BINARY) $(BIN_DIR)/$(BINARY); \
	fi
	@echo "==> Installed $(BIN_DIR)/$(BINARY)"

install-launch-agent: install-binary
	@mkdir -p $(LAUNCH_AGENT_DIR)
	@sed "s|__MINDOFAGENT_BIN__|$(BIN_DIR)/$(BINARY)|g" $(PLIST_TEMPLATE) > $(LAUNCH_AGENT_PLIST)
	@echo "==> Installed $(LAUNCH_AGENT_PLIST)"
	@launchctl bootout gui/$$UID/$(LAUNCH_AGENT_LABEL) 2>/dev/null || true
	@launchctl bootstrap gui/$$UID $(LAUNCH_AGENT_PLIST)
	@echo "==> LaunchAgent started — check menu bar for the network icon."
	@echo "    Logs: /tmp/mindofagent.log"

uninstall-launch-agent:
	@launchctl bootout gui/$$UID/$(LAUNCH_AGENT_LABEL) 2>/dev/null || true
	@rm -f $(LAUNCH_AGENT_PLIST)
	@echo "==> LaunchAgent removed. Binary at $(BIN_DIR)/$(BINARY) was left in place."

clean:
	rm -rf .build
