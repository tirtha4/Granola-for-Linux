#!/usr/bin/env bash
# Remove the Granola install created by granola-linux.sh.
# Your notes database in ~/.config/Granola is left alone unless you pass --purge.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications/granola}"
DESKTOP_FILE="${DESKTOP_FILE:-$HOME/.local/share/applications/granola.desktop}"
DATA_DIR="$HOME/.config/Granola"
APPARMOR_PROFILE=/etc/apparmor.d/granola

echo "This will remove:"
echo "  $INSTALL_DIR"
echo "  $DESKTOP_FILE"
[[ -f "$APPARMOR_PROFILE" ]] && echo "  $APPARMOR_PROFILE"
[[ "${1:-}" == "--purge" ]] && echo "  $DATA_DIR  (local notes cache and login)"
read -rp "Continue? [y/N] " reply
[[ "$reply" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

pkill -f "^$INSTALL_DIR/electron" 2>/dev/null || true
sleep 1
rm -rf "$INSTALL_DIR" "$DESKTOP_FILE"
[[ "${1:-}" == "--purge" ]] && rm -rf "$DATA_DIR"

if [[ -f "$APPARMOR_PROFILE" ]]; then
  echo "Removing $APPARMOR_PROFILE (needs sudo)"
  sudo apparmor_parser -R "$APPARMOR_PROFILE" 2>/dev/null || true
  sudo rm -f "$APPARMOR_PROFILE"
fi

command -v update-desktop-database >/dev/null && update-desktop-database "$(dirname "$DESKTOP_FILE")" 2>/dev/null || true
echo "Done."
