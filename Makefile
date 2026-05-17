PREFIX ?= /usr/local
BIN_DIR := $(PREFIX)/bin
BINARY := mindofagent
SOURCE_BINARY := .build/release/MindOfAgent

LAUNCH_AGENT_LABEL := io.stevedores.mindofagent
LAUNCH_AGENT_DIR := $(HOME)/Library/LaunchAgents
LAUNCH_AGENT_PLIST := $(LAUNCH_AGENT_DIR)/$(LAUNCH_AGENT_LABEL).plist
PLIST_TEMPLATE := deployment/macos/$(LAUNCH_AGENT_LABEL).plist.template

LOG_DIR := $(HOME)/Library/Logs/MindOfAgent
LOG_FILE := $(LOG_DIR)/mindofagent.log

.PHONY: help build build-release test install-binary install-launch-agent uninstall-launch-agent uninstall status clean

help:
	@echo "MindOfAgent — make targets"
	@echo ""
	@echo "  make build                  swift build (debug)"
	@echo "  make build-release          swift build -c release"
	@echo "  make test                   swift test (requires Xcode for XCTest)"
	@echo "  make install-launch-agent   build release, install binary, install LaunchAgent, start it"
	@echo "  make uninstall-launch-agent stop and remove the LaunchAgent (binary stays)"
	@echo "  make uninstall              remove the LaunchAgent AND the installed binary"
	@echo "  make status                 launchctl print of the agent (debug \"icon not showing\")"
	@echo "  make clean                  rm -rf .build"
	@echo ""
	@echo "First-run note: macOS Gatekeeper will block an unsigned binary on"
	@echo "first launch. The install target strips the quarantine xattr"
	@echo "defensively; if you hit \"developer cannot be verified\", right-"
	@echo "click the binary in Finder and choose Open, or run"
	@echo "  xattr -dr com.apple.quarantine $(BIN_DIR)/$(BINARY)"

build:
	swift build

build-release:
	swift build -c release

test:
	swift test

# Install the release binary into PREFIX/bin. Falls back to sudo when the
# directory isn't writable (the default /usr/local/bin on a stock Mac).
# Strips the com.apple.quarantine xattr defensively — no-op for a fresh
# `swift build` artifact, but matters once we ship release tarballs.
install-binary: build-release
	@if [ ! -w "$(BIN_DIR)" ] && [ -d "$(BIN_DIR)" ]; then \
		echo "==> Installing $(BINARY) to $(BIN_DIR) (requires sudo)"; \
		sudo install -m 0755 $(SOURCE_BINARY) $(BIN_DIR)/$(BINARY); \
		sudo xattr -dr com.apple.quarantine $(BIN_DIR)/$(BINARY) 2>/dev/null || true; \
	else \
		mkdir -p $(BIN_DIR); \
		install -m 0755 $(SOURCE_BINARY) $(BIN_DIR)/$(BINARY); \
		xattr -dr com.apple.quarantine $(BIN_DIR)/$(BINARY) 2>/dev/null || true; \
	fi
	@echo "==> Installed $(BIN_DIR)/$(BINARY)"

install-launch-agent: install-binary
	@mkdir -p $(LAUNCH_AGENT_DIR)
	@mkdir -p $(LOG_DIR)
	@sed -e "s|__MINDOFAGENT_BIN__|$(BIN_DIR)/$(BINARY)|g" \
	     -e "s|__HOME__|$(HOME)|g" \
	     $(PLIST_TEMPLATE) > $(LAUNCH_AGENT_PLIST)
	@echo "==> Installed $(LAUNCH_AGENT_PLIST)"
	@launchctl bootout gui/$$UID/$(LAUNCH_AGENT_LABEL) 2>/dev/null || true
	@launchctl bootstrap gui/$$UID $(LAUNCH_AGENT_PLIST)
	@echo "==> LaunchAgent started — check menu bar for the network icon."
	@echo "    Logs: $(LOG_FILE)"

uninstall-launch-agent:
	@launchctl bootout gui/$$UID/$(LAUNCH_AGENT_LABEL) 2>/dev/null || true
	@rm -f $(LAUNCH_AGENT_PLIST)
	@echo "==> LaunchAgent removed. Binary at $(BIN_DIR)/$(BINARY) was left in place."
	@echo "    (Use 'make uninstall' for a full removal.)"

# Full removal: LaunchAgent + binary. Log dir is left in place — logs are
# user data worth keeping after an uninstall.
uninstall: uninstall-launch-agent
	@if [ ! -w "$(BIN_DIR)" ] && [ -f "$(BIN_DIR)/$(BINARY)" ]; then \
		echo "==> Removing $(BIN_DIR)/$(BINARY) (requires sudo)"; \
		sudo rm -f $(BIN_DIR)/$(BINARY); \
	else \
		rm -f $(BIN_DIR)/$(BINARY); \
	fi
	@echo "==> Fully uninstalled. Logs left in $(LOG_DIR)."

# Debug helper. The first thing to check when users say "I installed it
# but the icon doesn't show" is whether launchd thinks the agent is loaded.
status:
	@launchctl print gui/$$UID/$(LAUNCH_AGENT_LABEL) 2>/dev/null \
		|| echo "$(LAUNCH_AGENT_LABEL) is not loaded (try: make install-launch-agent)"

clean:
	rm -rf .build
