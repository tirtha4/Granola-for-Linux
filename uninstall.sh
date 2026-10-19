#!/usr/bin/env bash
# Remove the Granola install created by granola-linux.sh.
# Your notes database in ~/.config/Granola is left alone unless you pass --purge.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications/granola}"
DESKTOP_FILE="${DESKTOP_FILE:-$HOME/.local/share/applications/granola.desktop}"
DATA_DIR="$HOME/.config/Granola"

echo "This will remove:"
echo "  $INSTALL_DIR"
echo "  $DESKTOP_FILE"
[[ "${1:-}" == "--purge" ]] && echo "  $DATA_DIR  (local notes cache and login)"
read -rp "Continue? [y/N] " reply
[[ "$reply" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

pkill -f "^$INSTALL_DIR/(granola|electron) " 2>/dev/null || true
sleep 1
rm -rf "$INSTALL_DIR" "$DESKTOP_FILE"
[[ "${1:-}" == "--purge" ]] && rm -rf "$DATA_DIR"

command -v update-desktop-database >/dev/null && update-desktop-database "$(dirname "$DESKTOP_FILE")" 2>/dev/null || true
echo "Done."
