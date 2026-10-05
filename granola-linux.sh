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

# Use npm exec, not npx: pnpm's npx shim mis-parses "node-gyp rebuild" and fails with
# "You forgot to tell me what to run when the files changes!"
( cd "$WORK/bs3" && CC="$CC" CXX="$CXX" npm exec --yes node-gyp -- rebuild --release \
    --runtime=electron --target="$EL_VER" --arch=x64 \
    --dist-url=https://electronjs.org/headers ) >"$WORK/build.log" 2>&1 \
  || { tail -30 "$WORK/build.log"; die "native build failed (full log: $WORK/build.log)"; }

cp "$WORK/bs3/build/Release/better_sqlite3.node" \
   "$WORK/bs3/build/Release/test_extension.node" "$BS3/build/Release/"


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

printf '\n\033[32m✓ Granola %s is installed.\033[0m\n' "$APP_VER"
printf '  Launch it from your application menu, or run:\n    %s\n\n' "$INSTALL_DIR/granola.sh"
