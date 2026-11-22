#!/usr/bin/env bash
# Remove the Granola install created by granola-linux.sh.
# Your notes database in ~/.config/Granola is left alone unless you pass --purge.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications/granola}"
DESKTOP_FILE="${DESKTOP_FILE:-$HOME/.local/share/applications/granola.desktop}"
DATA_DIR="$HOME/.config/Granola"
MIMEAPPS="$HOME/.config/mimeapps.list"

echo "This will remove:"
echo "  $INSTALL_DIR"
echo "  $DESKTOP_FILE"
echo "  granola:// mime associations"
[[ "${1:-}" == "--purge" ]] && echo "  $DATA_DIR  (local notes cache and login)"
read -rp "Continue? [y/N] " reply
[[ "$reply" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

if [[ -x "$INSTALL_DIR/electron" ]]; then
  # Match only this install's electron, not an unrelated Electron app.
  prefix="$INSTALL_DIR/electron"
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
    case "$cmd" in
      "$prefix"*) kill "$pid" 2>/dev/null || true ;;
    esac
  done < <(ps -eo pid=)
  sleep 1
fi

rm -rf "$INSTALL_DIR"
rm -f "$DESKTOP_FILE"
rmdir "$(dirname "$INSTALL_DIR")" 2>/dev/null || true
[[ "${1:-}" == "--purge" ]] && rm -rf "$DATA_DIR"

if [[ -f "$MIMEAPPS" ]]; then
  python3 - "$MIMEAPPS" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
lines = p.read_text().splitlines(True)
kept = [ln for ln in lines if "granola" not in ln.lower()]
if kept != lines:
    p.write_text("".join(kept))
PY
fi

command -v update-desktop-database >/dev/null && update-desktop-database "$(dirname "$DESKTOP_FILE")" 2>/dev/null || true
echo "Done."
