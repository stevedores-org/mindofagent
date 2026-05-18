#!/usr/bin/env bash
# Uninstall MindOfAgent — removes both launchd plists, the binary, the
# share dir, and the pkg receipt. Bundled into the .pkg at
# /usr/local/share/mindofagent/uninstall.sh and intended to be run with
# sudo.

set -e

LAUNCH_AGENT_LABEL="io.stevedores.mindofagent"
LAUNCH_DAEMON_LABEL="com.stevedores.mindofagent"
BIN="/usr/local/bin/mindofagent"
SHARE_DIR="/usr/local/share/mindofagent"

if [[ "$EUID" -ne 0 ]]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

# Bootout the LaunchAgent for whoever's currently logged in (best-effort
# — if no console user, fall through quietly).
CONSOLE_UID=$(stat -f '%u' /dev/console || echo "")
if [[ -n "$CONSOLE_UID" && "$CONSOLE_UID" != "0" ]]; then
  launchctl bootout "gui/$CONSOLE_UID/$LAUNCH_AGENT_LABEL" 2>/dev/null || true
fi

# Bootout the system daemon.
launchctl bootout "system/$LAUNCH_DAEMON_LABEL" 2>/dev/null || true

# Remove plists, binary, share dir.
rm -f "/Library/LaunchAgents/$LAUNCH_AGENT_LABEL.plist"
rm -f "/Library/LaunchDaemons/$LAUNCH_DAEMON_LABEL.plist"
rm -f "$BIN"
rm -rf "$SHARE_DIR"

# Forget the pkg receipt so a re-install is clean.
pkgutil --forget io.stevedores.mindofagent 2>/dev/null || true

echo "MindOfAgent uninstalled."
echo "Note: user log dirs (~/Library/Logs/MindOfAgent) were left in place."
