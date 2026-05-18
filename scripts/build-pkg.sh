#!/usr/bin/env bash
# Build a flat macOS installer (.pkg) bundling the release binary,
# both launchd plists, and a postinstall script that bootstraps the
# LaunchAgent + LaunchDaemon at install time.
#
# Outputs: dist/mindofagent-<VERSION>.pkg
#
# Sign with: DEVELOPER_ID_INSTALLER='Developer ID Installer: …' make pkg
# Unsigned builds work but trip Gatekeeper on first run — see make help.

set -euo pipefail

VERSION="${VERSION:-0.1.0}"
IDENTIFIER="io.stevedores.mindofagent"
BUILD_DIR=".build"
STAGING="$BUILD_DIR/pkg-staging"
SCRIPTS_STAGING="$BUILD_DIR/pkg-scripts"
OUT_DIR="dist"
COMPONENT_PKG="$BUILD_DIR/mindofagent-component-$VERSION.pkg"
OUT_PKG="$OUT_DIR/mindofagent-$VERSION.pkg"

LAUNCH_AGENT_LABEL="io.stevedores.mindofagent"
LAUNCH_DAEMON_LABEL="com.stevedores.mindofagent"
INSTALLED_BIN="/usr/local/bin/mindofagent"

echo "==> swift build -c release"
swift build -c release --product MindOfAgent

echo "==> staging payload in $STAGING"
rm -rf "$STAGING"

# Binary → /usr/local/bin/mindofagent
mkdir -p "$STAGING/usr/local/bin"
install -m 0755 "$BUILD_DIR/release/MindOfAgent" "$STAGING$INSTALLED_BIN"

# LaunchAgent template → /Library/LaunchAgents (system-wide; loads for
# every user that logs in after install). __HOME__ is rendered per-user
# by the postinstall script at install time.
mkdir -p "$STAGING/Library/LaunchAgents"
sed -e "s|__MINDOFAGENT_BIN__|$INSTALLED_BIN|g" \
    "deployment/macos/$LAUNCH_AGENT_LABEL.plist.template" \
    > "$STAGING/Library/LaunchAgents/$LAUNCH_AGENT_LABEL.plist"

# LaunchDaemon template → /Library/LaunchDaemons (system, root, headless).
mkdir -p "$STAGING/Library/LaunchDaemons"
sed -e "s|__MINDOFAGENT_BIN__|$INSTALLED_BIN|g" \
    "deployment/macos/$LAUNCH_DAEMON_LABEL.plist.template" \
    > "$STAGING/Library/LaunchDaemons/$LAUNCH_DAEMON_LABEL.plist"

# Bundled uninstaller → /usr/local/share/mindofagent/uninstall.sh
mkdir -p "$STAGING/usr/local/share/mindofagent"
install -m 0755 scripts/uninstall.sh \
    "$STAGING/usr/local/share/mindofagent/uninstall.sh"

# Postinstall script for the .pkg (must be literally named "postinstall")
echo "==> staging postinstall in $SCRIPTS_STAGING"
rm -rf "$SCRIPTS_STAGING"
mkdir -p "$SCRIPTS_STAGING"
install -m 0755 scripts/postinstall "$SCRIPTS_STAGING/postinstall"

# Signing — opt-in. Without DEVELOPER_ID_INSTALLER, builds work but the
# resulting .pkg has no Apple signature; the installer will warn the
# user on first run.
if [[ -n "${DEVELOPER_ID_INSTALLER:-}" ]]; then
  echo "==> signing with: $DEVELOPER_ID_INSTALLER"
  SIGN_ARGS=(--sign "$DEVELOPER_ID_INSTALLER")
else
  echo "==> DEVELOPER_ID_INSTALLER not set — building unsigned pkg" >&2
  SIGN_ARGS=()
fi

echo "==> pkgbuild ($COMPONENT_PKG)"
mkdir -p "$OUT_DIR"
pkgbuild \
  --root "$STAGING" \
  --scripts "$SCRIPTS_STAGING" \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  --install-location / \
  "${SIGN_ARGS[@]}" \
  "$COMPONENT_PKG"

echo "==> productbuild ($OUT_PKG)"
productbuild \
  --package "$COMPONENT_PKG" \
  "${SIGN_ARGS[@]}" \
  "$OUT_PKG"

echo ""
echo "Built: $OUT_PKG"
echo "       $(du -h "$OUT_PKG" | cut -f1)"
echo ""
if [[ -z "${DEVELOPER_ID_INSTALLER:-}" ]]; then
  echo "Note: unsigned .pkg. Users will need to right-click → Open in"
  echo "      Finder to bypass Gatekeeper on first install, or set"
  echo "      DEVELOPER_ID_INSTALLER before re-running."
fi
