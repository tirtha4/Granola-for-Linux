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
echo "  native messaging host manifests in browser profiles (~/.config, snap, flatpak)"
[[ "${1:-}" == "--purge" ]] && echo "  $DATA_DIR  (local notes cache and login)"
read -rp "Continue? [y/N] " reply
[[ "$reply" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

pkill -f "^$INSTALL_DIR/granola" 2>/dev/null || true
sleep 1
rm -rf "$INSTALL_DIR" "$DESKTOP_FILE"
[[ "${1:-}" == "--purge" ]] && rm -rf "$DATA_DIR"

# Same product list as granola-linux.sh (label | config dir | snap | flatpak).
while IFS='|' read -r label cdir snap flatpak; do
  [[ -z "$label" ]] && continue
  rm -f "$HOME/.config/$cdir/NativeMessagingHosts/com.granola.app.json"
  rmdir "$HOME/.config/$cdir/NativeMessagingHosts" 2>/dev/null || true
  if [[ -n "$snap" ]]; then
    rm -f "$HOME/snap/$snap/current/.config/$cdir/NativeMessagingHosts/com.granola.app.json"
    rmdir "$HOME/snap/$snap/current/.config/$cdir/NativeMessagingHosts" 2>/dev/null || true
  fi
  if [[ -n "$flatpak" ]]; then
    rm -f "$HOME/.var/app/$flatpak/config/$cdir/NativeMessagingHosts/com.granola.app.json"
    rmdir "$HOME/.var/app/$flatpak/config/$cdir/NativeMessagingHosts" 2>/dev/null || true
  fi
done <<'EOF'
google-chrome|google-chrome|chrome|com.google.Chrome
google-chrome-beta|google-chrome-beta||com.google.ChromeBeta
google-chrome-unstable|google-chrome-unstable||com.google.ChromeDev
chromium|chromium|chromium|org.chromium.Chromium
chromium-browser|chromium-browser||
chromium-beta|chromium-beta||
microsoft-edge|microsoft-edge|microsoft-edge|com.microsoft.Edge
microsoft-edge-beta|microsoft-edge-beta||com.microsoft.EdgeBeta
microsoft-edge-dev|microsoft-edge-dev||com.microsoft.EdgeDev
brave-browser|BraveSoftware/Brave-Browser|brave|com.brave.Browser
vivaldi|vivaldi||com.vivaldi.Vivaldi
opera|opera||com.opera.Opera
EOF

# Revoke the flatpak sandbox overrides the installer granted.
if command -v flatpak >/dev/null; then
  for id in com.google.Chrome com.google.ChromeBeta com.google.ChromeDev \
            org.chromium.Chromium com.microsoft.Edge com.microsoft.EdgeBeta \
            com.microsoft.EdgeDev com.brave.Browser com.vivaldi.Vivaldi \
            com.opera.Opera; do
    flatpak override --user --nofilesystem=/tmp --nofilesystem="$INSTALL_DIR" "$id" 2>/dev/null || true
  done
fi

command -v update-desktop-database >/dev/null && update-desktop-database "$(dirname "$DESKTOP_FILE")" 2>/dev/null || true
echo "Done."
