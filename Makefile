PREFIX ?= /usr/local
BIN_DIR := $(PREFIX)/bin
BINARY := mindofagent
SOURCE_BINARY := .build/release/MindOfAgent

LAUNCH_AGENT_LABEL := io.stevedores.mindofagent
LAUNCH_AGENT_DIR := $(HOME)/Library/LaunchAgents
LAUNCH_AGENT_PLIST := $(LAUNCH_AGENT_DIR)/$(LAUNCH_AGENT_LABEL).plist
LAUNCH_AGENT_TEMPLATE := deployment/macos/$(LAUNCH_AGENT_LABEL).plist.template

LAUNCH_DAEMON_LABEL := com.stevedores.mindofagent
LAUNCH_DAEMON_DIR := /Library/LaunchDaemons
LAUNCH_DAEMON_PLIST := $(LAUNCH_DAEMON_DIR)/$(LAUNCH_DAEMON_LABEL).plist
LAUNCH_DAEMON_TEMPLATE := deployment/macos/$(LAUNCH_DAEMON_LABEL).plist.template

LOG_DIR := $(HOME)/Library/Logs/MindOfAgent
LOG_FILE := $(LOG_DIR)/mindofagent.log
DAEMON_LOG := /var/log/mindofagent-daemon.log

.PHONY: help build build-release test install-binary \
        install-launch-agent uninstall-launch-agent \
        install-launch-daemon uninstall-launch-daemon \
        uninstall status daemon-status pkg clean

help:
	@echo "MindOfAgent — make targets"
	@echo ""
	@echo "  make build                  swift build (debug)"
	@echo "  make build-release          swift build -c release"
	@echo "  make test                   swift test (requires Xcode for XCTest)"
	@echo "  make install-launch-agent   build release, install binary, install LaunchAgent, start it"
	@echo "                              (per-user, menu-bar mode — pick this for an interactive Mac)"
	@echo "  make uninstall-launch-agent stop and remove the LaunchAgent (binary stays)"
	@echo "  make install-launch-daemon  install the system-wide LaunchDaemon for headless mode"
	@echo "                              (root, --daemon, no menu — pick this for a mac-mini cluster node)"
	@echo "  make uninstall-launch-daemon stop and remove the LaunchDaemon (binary stays)"
	@echo "  make uninstall              remove BOTH plists AND the installed binary"
	@echo "  make status                 launchctl print of the user LaunchAgent"
	@echo "  make daemon-status          launchctl print of the system LaunchDaemon"
	@echo "  make pkg                    build a distributable .pkg installer in dist/"
	@echo "                              (set DEVELOPER_ID_INSTALLER='Developer ID Installer: …'"
	@echo "                              to sign; unsigned otherwise)"
	@echo "  make clean                  rm -rf .build dist"
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
	     $(LAUNCH_AGENT_TEMPLATE) > $(LAUNCH_AGENT_PLIST)
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

# LaunchDaemon (system-wide, root). Installs to /Library/LaunchDaemons,
# requires sudo for the install + bootstrap, and runs the binary with
# --daemon so no SwiftUI/MenuBarExtra is started. Right answer for a
# headless mac-mini cluster node with no logged-in user.
install-launch-daemon: install-binary
	@TMP=$$(mktemp) && \
	sed -e "s|__MINDOFAGENT_BIN__|$(BIN_DIR)/$(BINARY)|g" \
	    $(LAUNCH_DAEMON_TEMPLATE) > $$TMP && \
	echo "==> Installing $(LAUNCH_DAEMON_PLIST) (requires sudo)" && \
	sudo install -m 0644 -o root -g wheel $$TMP $(LAUNCH_DAEMON_PLIST) && \
	rm -f $$TMP
	@sudo launchctl bootout system/$(LAUNCH_DAEMON_LABEL) 2>/dev/null || true
	@sudo launchctl bootstrap system $(LAUNCH_DAEMON_PLIST)
	@echo "==> LaunchDaemon started — daemon log: $(DAEMON_LOG)"

uninstall-launch-daemon:
	@sudo launchctl bootout system/$(LAUNCH_DAEMON_LABEL) 2>/dev/null || true
	@sudo rm -f $(LAUNCH_DAEMON_PLIST)
	@echo "==> LaunchDaemon removed. Binary at $(BIN_DIR)/$(BINARY) was left in place."

# Full removal: both plists + binary. Log dirs are left in place — logs
# are debugging artifacts worth keeping after an uninstall.
uninstall: uninstall-launch-agent uninstall-launch-daemon
	@if [ ! -w "$(BIN_DIR)" ] && [ -f "$(BIN_DIR)/$(BINARY)" ]; then \
		echo "==> Removing $(BIN_DIR)/$(BINARY) (requires sudo)"; \
		sudo rm -f $(BIN_DIR)/$(BINARY); \
	else \
		rm -f $(BIN_DIR)/$(BINARY); \
	fi
	@echo "==> Fully uninstalled."
	@echo "    User logs:   $(LOG_DIR) (left in place)"
	@echo "    Daemon log:  $(DAEMON_LOG) (left in place)"

# Debug helpers. First thing to check when users report "icon doesn't show"
# (LaunchAgent) or "headless node is offline" (LaunchDaemon).
status:
	@launchctl print gui/$$UID/$(LAUNCH_AGENT_LABEL) 2>/dev/null \
		|| echo "$(LAUNCH_AGENT_LABEL) is not loaded (try: make install-launch-agent)"

daemon-status:
	@sudo launchctl print system/$(LAUNCH_DAEMON_LABEL) 2>/dev/null \
		|| echo "$(LAUNCH_DAEMON_LABEL) is not loaded (try: make install-launch-daemon)"

pkg:
	@VERSION="$${VERSION:-0.1.0}" scripts/build-pkg.sh

clean:
	rm -rf .build dist
