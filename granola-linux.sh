#!/usr/bin/env bash

set -euo pipefail

DMG="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications/granola}"
CACHE_DIR="${CACHE_DIR:-$SCRIPT_DIR/.cache}"
DESKTOP_FILE="${DESKTOP_FILE:-$HOME/.local/share/applications/granola.desktop}"
RES="Granola/Granola.app/Contents/Resources"

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }

[[ -n "$DMG" ]] || die "usage: $0 <path-to-granola.dmg>   (INSTALL_DIR=$INSTALL_DIR)"
[[ -f "$DMG" ]] || die "no such file: $DMG"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$CACHE_DIR"


step "Checking prerequisites"

for cmd in node npm python3 curl make; do
  command -v "$cmd" >/dev/null || die "'$cmd' not found. Please install it."
done


SEVENZZ="$(command -v 7zz || true)"
if [[ -z "$SEVENZZ" ]]; then
  SEVENZZ="$CACHE_DIR/7zz"
  if [[ ! -x "$SEVENZZ" ]]; then
    info "7zz not found, downloading the official static build (LZFSE support)"
    curl -fsSL -o "$WORK/7z.tar.xz" https://www.7-zip.org/a/7z2501-linux-x64.tar.xz \
      || die "could not download 7zz; install it manually and re-run"
    tar xf "$WORK/7z.tar.xz" -C "$CACHE_DIR" 7zz
    chmod +x "$SEVENZZ"
  fi
fi
info "7zz:  $SEVENZZ"


CXX=""
for v in 15 14 13 12 11; do
  if command -v "g++-$v" >/dev/null; then CXX="g++-$v"; CC="gcc-$v"; break; fi
done
if [[ -z "$CXX" ]] && command -v g++ >/dev/null; then
  if [[ "$(g++ -dumpversion | cut -d. -f1)" -ge 11 ]]; then CXX=g++; CC=gcc; fi
fi
[[ -n "$CXX" ]] || die "need g++ 11 or newer (Electron 42 headers require C++20). Try: sudo apt install g++-11"
info "compiler: $CXX ($($CXX -dumpversion))"


step "Reading Electron version from the .dmg"

"$SEVENZZ" e "$DMG" \
  "Granola/Granola.app/Contents/Frameworks/Electron Framework.framework/Versions/A/Resources/Info.plist" \
  -o"$WORK/fw" -y >/dev/null || die "could not read the .dmg (is it a Granola disk image?)"
EL_VER="$(grep -A1 CFBundleVersion "$WORK/fw/Info.plist" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[[ -n "$EL_VER" ]] || die "could not determine the Electron version"
info "Electron $EL_VER"

step "Fetching the Linux Electron runtime"

ZIP="$CACHE_DIR/electron-v$EL_VER-linux-x64.zip"
if [[ ! -f "$ZIP" ]]; then
  URL="https://github.com/electron/electron/releases/download/v$EL_VER/electron-v$EL_VER-linux-x64.zip"
  info "downloading $URL"
  curl -fL --progress-bar -o "$ZIP.part" "$URL" || die "download failed"
  mv "$ZIP.part" "$ZIP"
else
  info "using cached $(basename "$ZIP")"
fi

rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
"$SEVENZZ" x "$ZIP" -o"$INSTALL_DIR" -y >/dev/null

# Rename the runtime binary away from "electron": that is how Electron tells a
# stock/dev build from a packaged one (app.isPackaged). Granola's consent host
# lookup keys off isPackaged -- packaged builds resolve to
# resources/native-host/meet-consent-host (which is exactly the layout Granola
# ships in the macOS .dmg), while dev builds resolve to
# resources/app.asar/native/<arch>/meet-consent-host, a path that sits inside
# the asar archive and can never exist on disk. Since app update 7.529.x
# dropped dirname() from that path, speaker detection stopped working; making
# the runtime appear packaged restores it without touching app code.
mv "$INSTALL_DIR/electron" "$INSTALL_DIR/granola"
chmod +x "$INSTALL_DIR/granola"
rm -f "$INSTALL_DIR/resources/default_app.asar"   # the "welcome to Electron" demo


step "Extracting the app payload"


"$SEVENZZ" x "$DMG" "$RES/app.asar" "$RES/app.asar.unpacked" "$RES/icons" \
  -o"$WORK/dmg" -y >/dev/null
cp -r "$WORK/dmg/$RES/app.asar" "$WORK/dmg/$RES/app.asar.unpacked" \
      "$WORK/dmg/$RES/icons" "$INSTALL_DIR/resources/"
cp "$INSTALL_DIR/resources/icons/icon.png" "$INSTALL_DIR/granola-icon.png"
"$SEVENZZ" e "$DMG" "Granola/Granola.app/Contents/Info.plist" -o"$WORK/appinfo" -y >/dev/null 2>&1 || true
APP_VER="$(grep -A1 CFBundleShortVersionString "$WORK/appinfo/Info.plist" 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"
info "Granola ${APP_VER:-?} payload installed"


step "Patching the platform string"

# api.granola.ai answers 500 Internal Server Error to any request carrying
# platform=linux, including the sign-in URL, so login is impossible without
# this. The app maps darwin->macOS and win32->Windows and passes anything else
# through verbatim; rewrite that fallback so Linux reports Windows.
#
# The replacement is byte-for-byte the same length (padded with spaces) because
# an .asar has a header that records file offsets. Stock Electron does not
# verify asar integrity on Linux, so an in-place edit is safe.
python3 - "$INSTALL_DIR/resources/app.asar" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); data = p.read_bytes(); total = 0
for pat in (b'?`Windows`:window.electron.platform', b'?`Windows`:process.platform'):
    rep = b'?`Windows`:`Windows`'.ljust(len(pat))
    total += data.count(pat)
    data = data.replace(pat, rep)
if total == 0:
    sys.exit("no platform fallback found. Granola's bundler output may have changed")
p.write_bytes(data)
print(f"    rewrote {total} platform fallback(s)")
PYEOF


step "Rebuilding better-sqlite3-multiple-ciphers for Linux"

# Granola ships a *patched* fork of better-sqlite3-multiple-ciphers: it adds an
# updateHook() method that the renderer's cache layer calls on startup. Upstream
# npm builds do not have it, so dropping in a stock prebuilt binary gets you a
# window that dies with "r.updateHook is not a function".
#
# Their full C++ source is inside app.asar.unpacked, so build *that*. Only
# binding.gyp is missing from the bundle; take it from the matching npm release.
BS3="$INSTALL_DIR/resources/app.asar.unpacked/node_modules/better-sqlite3-multiple-ciphers"
BS3_VER="$(node -p "require('$BS3/package.json').version")"
info "building Granola's fork of v$BS3_VER from source"

cp -r "$BS3" "$WORK/bs3"
( cd "$WORK" && npm pack "better-sqlite3-multiple-ciphers@$BS3_VER" --silent >/dev/null \
    && tar xzf better-sqlite3-multiple-ciphers-*.tgz ) || die "could not fetch binding.gyp from npm"
cp "$WORK/package/binding.gyp" "$WORK/bs3/"

( cd "$WORK/bs3" && CC="$CC" CXX="$CXX" npx --yes node-gyp rebuild --release \
    --runtime=electron --target="$EL_VER" --arch=x64 \
    --dist-url=https://electronjs.org/headers ) >"$WORK/build.log" 2>&1 \
  || { tail -30 "$WORK/build.log"; die "native build failed (full log: $WORK/build.log)"; }

cp "$WORK/bs3/build/Release/better_sqlite3.node" \
   "$WORK/bs3/build/Release/test_extension.node" "$BS3/build/Release/"


step "Installing the Chrome extension native messaging host"

# Granola's Chrome extension ("AI notes for Google Meet", and the webcam/consent
# companion) talks to the app through a native messaging host named
# com.granola.app. On macOS the app registers that host by writing a manifest
# into ~/Library/Application Support/...; its browser detection only looks at
# macOS locations too, so on a swapped-in Linux runtime nothing ever gets
# registered and the extension reports "native messaging host not found."
#
# The host itself is a tiny bridge with two well-defined half-protocols, both
# readable out of app.asar:
#
#   Chrome <-> host  4-byte little-endian length prefix, then UTF-8 JSON
#   host <-> app     newline-delimited JSON over a unix socket at
#                    /tmp/granola-meet-consent-<sha256($HOME)[0:12]>.sock
#
# The app also insists the host file exists at resources/native-host/
# meet-consent-host -- the packaged-app layout, exactly where the macOS .dmg
# ships it -- before it will start its socket server at all. Because the
# runtime binary above was renamed (isPackaged=true), the packaged branch of
# that lookup is what runs, so this step is not optional. On a fresh run of
# this script that directory was wiped with $INSTALL_DIR.
NATIVE_DIR="$INSTALL_DIR/resources/native-host"
mkdir -p "$NATIVE_DIR"

cp "$SCRIPT_DIR/native/meet-consent-host" "$SCRIPT_DIR/native/meet-consent-bridge.js" "$NATIVE_DIR/"
chmod +x "$NATIVE_DIR/meet-consent-host"

# Register com.granola.app in every browser profile that exists here. Chrome
# requires the manifest filename to match the "name" field and `path` to be
# absolute. Allowed origins mirror the extension ids the app itself uses.
MANIFEST="$(cat <<EOF
{
  "name": "com.granola.app",
  "description": "Granola meeting notes - consent messaging",
  "path": "$NATIVE_DIR/meet-consent-host",
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://opaadbjlebbbnmjjgdmdllingedoleml/",
    "chrome-extension://ephifgbopdapgehlpnakaddgmmgcbmjp/",
    "chrome-extension://fihphjchjdimokpleomddhnapnobdphn/"
  ]
}
EOF
)"
registered=0
flatpak_ids=""
snap_labels=""

# Register $MANIFEST under a browser config dir if that dir exists. $1 is a
# human label, $2 the absolute path to the config dir (NativeMessagingHosts is
# appended). Returns 1 when the dir is absent so callers know whether the
# browser was actually found there.
register_host() {
  local label="$1" base="$2"
  [[ -d "$base" ]] || return 1
  mkdir -p "$base/NativeMessagingHosts"
  printf '%s\n' "$MANIFEST" > "$base/NativeMessagingHosts/com.granola.app.json"
  info "registered host for $label"
  registered=$((registered + 1))
  return 0
}

# Chromium-family products, one row per entry:  label | config dir | snap |
# flatpak id. A blank snap/flatpak column means that product ships no package
# of that kind (Arc is omitted: it has no Linux build).
#
# Beyond the classic ~/.config/<dir> location the sandboxed packaging that the
# big distros default to is covered too:
#   snap    -> ~/snap/<name>/current/.config/<dir>   browsers get a per-snap HOME
#   flatpak -> ~/.var/app/<id>/config/<dir>          flatpak HOME + XDG_CONFIG_HOME
# Both confine the browser, so a manifest alone is not enough: see the notes
# and sandbox overrides below.
while IFS='|' read -r label cdir snap flatpak; do
  [[ -z "$label" ]] && continue

  register_host "$label" "$HOME/.config/$cdir" || true

  if [[ -n "$snap" ]] && register_host "$label (snap)" "$HOME/snap/$snap/current/.config/$cdir"; then
    snap_labels+="$label "
  fi

  if [[ -n "$flatpak" ]] && register_host "$label (flatpak)" "$HOME/.var/app/$flatpak/config/$cdir"; then
    flatpak_ids+="$flatpak "
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

# Snap browsers are strictly confined: their mount namespace rewrites HOME and
# /tmp, and AppArmor generally blocks them from exec'ing a host binary outside
# the snap. The manifest above at least lets the extension find the host, and
# on Ubuntu 22.04+ a patched XDG desktop portal can mediate launching it, but
# that is distro-specific and has regressed before. Say so instead of implying
# registration == working.
if [[ -n "$snap_labels" ]]; then
  warn "snap browsers found (${snap_labels% }): the snap sandbox limits them."
  warn "  A strictly confined snap may refuse to launch a host binary under"
  warn "  $INSTALL_DIR and gives it a private /tmp. Use an unsandboxed build"
  warn "  (Google Chrome .deb, a distro chromium .deb, or a tarball/AppImage)"
  warn "  for the most reliable speaker detection."
fi

# Flatpak browsers are sandboxed the same way, so the manifest path alone is
# not enough. The browser needs filesystem access to $INSTALL_DIR to exec the
# host, and host /tmp must be shared or Granola's control socket
# (/tmp/granola-meet-consent-*.sock) is out of reach. Grant both, best-effort,
# and say how to undo.
if [[ -n "$flatpak_ids" ]]; then
  for id in $flatpak_ids; do
    if command -v flatpak >/dev/null \
        && flatpak override --user --filesystem="$INSTALL_DIR" --filesystem=/tmp "$id" 2>/dev/null; then
      info "flatpak $id: granted filesystem access to $INSTALL_DIR and to host /tmp"
    else
      info "flatpak $id: grant access manually so the host is reachable:"
      info "  flatpak override --user --filesystem=$INSTALL_DIR --filesystem=/tmp $id"
    fi
  done
  warn "flatpak browsers are sandboxed; sharing host /tmp weakens that sandbox."
  warn "  Undo with: flatpak override --user --nofilesystem=/tmp --nofilesystem=$INSTALL_DIR <app-id>"
fi

[[ "$registered" -gt 0 ]] || info "no Chromium-family browser profiles found under ~/.config, ~/snap, or ~/.var/app (install the extension inside a browser, then re-run this script; Granola's extension is Chrome-only, Firefox is not supported)"


step "Installing launcher and desktop entry"

cat > "$INSTALL_DIR/granola.sh" <<EOF
#!/usr/bin/env bash
DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
exec "\$DIR/granola" --ozone-platform-hint=auto "\$@"
EOF
chmod +x "$INSTALL_DIR/granola.sh"

mkdir -p "$(dirname "$DESKTOP_FILE")"
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Granola
Comment=AI Notepad for meetings
Exec=$INSTALL_DIR/granola.sh %U
Icon=$INSTALL_DIR/granola-icon.png
Terminal=false
Categories=Office;Utility;
StartupWMClass=granola
MimeType=x-scheme-handler/granola;
EOF

command -v update-desktop-database >/dev/null && update-desktop-database "$(dirname "$DESKTOP_FILE")" 2>/dev/null || true

command -v xdg-mime >/dev/null && xdg-mime default "$(basename "$DESKTOP_FILE")" x-scheme-handler/granola 2>/dev/null || true


step "Smoke-testing the native module"

ELECTRON_RUN_AS_NODE=1 NODE_PATH="$INSTALL_DIR/resources/app.asar/node_modules" \
  "$INSTALL_DIR/granola" -e "
    const Database = require('$BS3/lib/index.js');
    const db = new Database('$WORK/smoke.db');
    db.pragma(\"cipher='sqlcipher'\");
    db.pragma(\"key='smoketest'\");
    db.exec('CREATE TABLE t(a)');
    let fired = false;
    db.updateHook(() => { fired = true; });
    db.prepare('INSERT INTO t VALUES (1)').run();
    if (db.prepare('SELECT count(*) c FROM t').get().c !== 1) throw new Error('insert failed');
    if (!fired) throw new Error('updateHook did not fire');
    db.close();
  " || die "smoke test failed, the app would not start"
info "encrypted database + updateHook both work"


step "Smoke-testing the native messaging bridge"

# Stand in for the app's socket server, push a framed message through the host
# in both directions, and confirm what comes out the other end.
cat > "$WORK/bridge-smoke.js" <<'BRIDGE_TEST_EOF'
'use strict';
const net = require('net');
const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const sockPath = path.join(os.tmpdir(), `granola-socket-${process.pid}.sock`);
const host = process.argv[2];
let child = null;
const fail = (m) => { console.error('    ' + m); child && child.kill(); process.exit(1); };
const deadline = setTimeout(() => fail('bridge smoke test timed out'), 30000);

const server = net.createServer((conn) => {
  let buf = '';
  conn.on('data', (d) => {
    buf += d.toString();
    let n;
    while ((n = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, n); buf = buf.slice(n + 1);
      let msg; try { msg = JSON.parse(line); } catch { continue; }
      if (msg.type !== 'smoke') continue;
      conn.write(JSON.stringify({ type: 'smoke-reply', saw: msg.type }) + '\n');
    }
  });
});
server.listen(sockPath, () => {
  child = spawn(host, [], {
    env: Object.assign({}, process.env, { GRANOLA_BRIDGE_SOCKET: sockPath }),
    stdio: ['pipe', 'pipe', 'inherit'],
  });
  let out = Buffer.alloc(0);
  child.stdout.on('data', (d) => {
    out = Buffer.concat([out, d]);
    while (out.length >= 4) {
      const len = out.readUInt32LE(0);
      if (out.length < 4 + len) break;
      const json = out.subarray(4, 4 + len).toString('utf8');
      out = out.subarray(4 + len);
      let reply; try { reply = JSON.parse(json); } catch { continue; }
      if (reply.type === 'smoke-reply' && reply.saw === 'smoke') {
        clearTimeout(deadline);
        child.kill();
        console.log('    chrome <-> bridge <-> app socket: both directions OK');
        process.exit(0);
      }
    }
  });
  child.on('exit', (code) => { if (code && code !== 0) fail(`bridge exited early (${code})`); });
  child.on('error', (e) => fail(`bridge failed to spawn: ${e.message}`));

  const body = JSON.stringify({ type: 'smoke' });
  const frame = Buffer.alloc(4 + Buffer.byteLength(body));
  frame.writeUInt32LE(Buffer.byteLength(body), 0);
  frame.write(body, 4);
  child.stdin.write(frame);
});
server.on('error', (e) => fail(`test socket: ${e.message}`));
process.on('exit', () => { try { fs.unlinkSync(sockPath); } catch {} });
BRIDGE_TEST_EOF

ELECTRON_RUN_AS_NODE=1 NODE_PATH="$INSTALL_DIR/resources/app.asar/node_modules" \
  "$INSTALL_DIR/granola" "$WORK/bridge-smoke.js" "$NATIVE_DIR/meet-consent-host" \
  || die "native messaging host failed its smoke test"

printf '\n\033[32m✓ Granola %s is installed.\033[0m\n' "$APP_VER"
printf '  Launch it from your application menu, or run:\n    %s\n\n' "$INSTALL_DIR/granola.sh"
