#!/usr/bin/env bash

set -euo pipefail

DMG="${1:-}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications/granola}"
CACHE_DIR="${CACHE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.cache}"
DESKTOP_FILE="${DESKTOP_FILE:-$HOME/.local/share/applications/granola.desktop}"
RES="Granola/Granola.app/Contents/Resources"

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }

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
chmod +x "$INSTALL_DIR/electron"
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
# The app also insists the host file exists at resources/native/<arch>/
# meet-consent-host (arch from the runtime's own process.arch) before it will
# start its socket server at all, so this step is not optional. On a fresh run
# of this script that directory was wiped with $INSTALL_DIR.
NATIVE_ARCH="$(ELECTRON_RUN_AS_NODE=1 "$INSTALL_DIR/electron" -e 'process.stdout.write(process.arch)')"
[[ -n "$NATIVE_ARCH" ]] || die "could not determine the runtime architecture"
NATIVE_DIR="$INSTALL_DIR/resources/native/$NATIVE_ARCH"
mkdir -p "$NATIVE_DIR"

cat > "$NATIVE_DIR/meet-consent-host" <<'HOSTEOF'
#!/usr/bin/env bash
# Native messaging host entry point for Granola on Linux. Chrome spawns this
# file directly; it runs the JS bridge with the Electron runtime we ship, in
# plain node mode (ELECTRON_RUN_AS_NODE), so no system Node is required.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec env ELECTRON_RUN_AS_NODE=1 "$DIR/../../../electron" "$DIR/meet-consent-bridge.js" "$@"
HOSTEOF

cat > "$NATIVE_DIR/meet-consent-bridge.js" <<'BRIDGEEOF'
#!/usr/bin/env node
// Drop-in Linux replacement for Granola's compiled meet-consent-host binary.
// It relays between Chrome and the app socket, both directions:
//   stdin/stdout : 4-byte little-endian length + JSON (Chrome native messaging)
//   unix socket  : newline-delimited JSON (the app's framing)
'use strict';
const os = require('os');
const crypto = require('crypto');
const net = require('net');

// The app binds /tmp/granola-meet-consent-<sha256($HOME)[0:12]>.sock and also
// listens on a legacy /tmp/granola-meet-consent.sock. GRANOLA_BRIDGE_SOCKET
// overrides the candidates (used by the installer's smoke test).
const hash = crypto.createHash('sha256').update(os.homedir()).digest('hex').slice(0, 12);
const candidates = (process.env.GRANOLA_BRIDGE_SOCKET || '')
  .split(':').filter(Boolean)
  .concat([`/tmp/granola-meet-consent-${hash}.sock`, '/tmp/granola-meet-consent.sock']);

let sock = null;
let connecting = false;
let stdinBuf = Buffer.alloc(0);
let socketBuf = Buffer.alloc(0);
let pending = [];

function toChrome(json) {
  const body = Buffer.from(json, 'utf8');
  const out = Buffer.alloc(4 + body.length);
  out.writeUInt32LE(body.length, 0); // native byte order (little-endian on supported targets)
  body.copy(out, 4);
  process.stdout.write(out);
}

function stake(local) {
  const s = net.createConnection(local);
  s.on('connect', () => {
    connecting = false;
    if (sock && sock !== s) { s.destroy(); return; }
    sock = s;
    if (pending.length) {
      const batch = pending; pending = [];
      sock.write(Buffer.concat(batch));
    }
  });
  s.on('data', (d) => {
    socketBuf = Buffer.concat([socketBuf, d]);
    let n;
    while ((n = socketBuf.indexOf(0x0a)) >= 0) {
      toChrome(socketBuf.subarray(0, n).toString('utf8'));
      socketBuf = socketBuf.subarray(n + 1);
    }
  });
  s.on('error', () => { connecting = false; if (sock === s) sock = null; s.destroy(); });
  s.on('close', () => { connecting = false; if (sock === s) sock = null; });
  return s;
}

let slot = 0;
function connect() {
  if (!sock && !connecting) {
    connecting = true;
    stake(candidates[slot++ % candidates.length]);
  }
}
connect();
setInterval(connect, 1500);

process.stdin.on('data', (d) => {
  stdinBuf = Buffer.concat([stdinBuf, d]);
  while (stdinBuf.length >= 4) {
    // Length prefix is 32-bit in the platform's native byte order; all
    // supported targets (x86-64/arm64) are little-endian, hence readUInt32LE.
    const len = stdinBuf.readUInt32LE(0);
    // Chrome caps messages sent to a host at 64 MiB; 1 MiB is the limit in
    // the host->Chrome direction only. A larger length means the stream is
    // corrupt with no recoverable framing, so fail rather than misparse.
    if (len > 64 * 1024 * 1024) {
      process.stderr.write('meet-consent-host: invalid frame length ' + len + '\n');
      process.exit(1);
    }
    if (stdinBuf.length < 4 + len) break;
    const body = stdinBuf.subarray(4, 4 + len);
    stdinBuf = stdinBuf.subarray(4 + len);
    const line = Buffer.concat([body, Buffer.from([0x0a])]);
    if (sock) sock.write(line); else pending.push(line);
  }
});
process.stdin.on('end', () => process.exit(0));
BRIDGEEOF
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
for dir in \
  google-chrome google-chrome-beta google-chrome-unstable \
  chromium chromium-beta microsoft-edge microsoft-edge-dev \
  BraveSoftware/Brave-Browser vivaldi opera Arc; do
  base="$HOME/.config/$dir"
  [[ -d "$base" ]] || continue
  host_dir="$base/NativeMessagingHosts"
  mkdir -p "$host_dir"
  printf '%s\n' "$MANIFEST" > "$host_dir/com.granola.app.json"
  info "registered host for $dir"
  registered=$((registered + 1))
done
[[ "$registered" -gt 0 ]] || info "no browser profiles found under ~/.config (install the extension inside a browser, then re-run this script)"


step "Installing launcher and desktop entry"

cat > "$INSTALL_DIR/granola.sh" <<EOF
#!/usr/bin/env bash
DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
exec "\$DIR/electron" --ozone-platform-hint=auto "\$@"
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
  "$INSTALL_DIR/electron" -e "
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
  "$INSTALL_DIR/electron" "$WORK/bridge-smoke.js" "$NATIVE_DIR/meet-consent-host" \
  || die "native messaging host failed its smoke test"

printf '\n\033[32m✓ Granola %s is installed.\033[0m\n' "$APP_VER"
printf '  Launch it from your application menu, or run:\n    %s\n\n' "$INSTALL_DIR/granola.sh"
