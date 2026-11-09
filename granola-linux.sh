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


# granola.ai/download now serves a ~1 MB "Install Granola.app" that downloads
# the real app at install time. It has no app.asar, so fetch the full .dmg the
# same way that stub does: ask the versions API, then follow download.granola.ai.
if "$SEVENZZ" l "$DMG" 2>/dev/null | grep -q 'Install Granola.app/Contents/MacOS/GranolaInstaller'; then
  step "Fetching the full Granola .dmg"
  info "$(basename "$DMG") is Granola's downloader stub, not the app itself"
  VER="$(curl -fsS https://api.granola.ai/v1/get-versions | grep -oE '"download":"[0-9.]+"' | grep -oE '[0-9.]+')" \
    || die "could not ask api.granola.ai for the latest version"
  DMG="$CACHE_DIR/Granola-$VER-mac-universal.dmg"
  if [[ ! -f "$DMG" ]]; then
    info "downloading Granola $VER"
    curl -fL --progress-bar -o "$DMG.part" "https://download.granola.ai/?platform=mac&version=$VER" \
      || die "download failed"
    mv "$DMG.part" "$DMG"
  else
    info "using cached $(basename "$DMG")"
  fi
fi

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
# Granola up to 7.668 shipped the fork's full C++ source inside
# app.asar.unpacked (missing only binding.gyp), so we built that. From 7.749 on
# the bundle has just the compiled macOS binary and lib/*.js. In that case,
# rebuild the fork from the matching npm release plus the patch in patches/,
# which was taken from Granola's last source-bearing bundle.
BS3="$INSTALL_DIR/resources/app.asar.unpacked/node_modules/better-sqlite3-multiple-ciphers"
BS3_VER="$(node -p "require('$BS3/package.json').version")"
BS3_PATCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patches/better-sqlite3-multiple-ciphers-$BS3_VER.patch"

( cd "$WORK" && npm pack "better-sqlite3-multiple-ciphers@$BS3_VER" --silent >/dev/null \
    && tar xzf better-sqlite3-multiple-ciphers-*.tgz ) || die "could not fetch v$BS3_VER from npm"

if [[ -d "$BS3/src" ]]; then
  info "building Granola's bundled fork of v$BS3_VER from source"
  cp -r "$BS3" "$WORK/bs3"
  cp "$WORK/package/binding.gyp" "$WORK/bs3/"
else
  info "bundle has no C++ source; patching upstream v$BS3_VER with updateHook support"
  [[ -f "$BS3_PATCH" ]] || die "no patch for better-sqlite3-multiple-ciphers v$BS3_VER (expected $BS3_PATCH)"
  command -v patch >/dev/null || die "'patch' not found. Please install it."
  mv "$WORK/package" "$WORK/bs3"
  patch -d "$WORK/bs3" -p1 --quiet <"$BS3_PATCH" || die "could not apply $(basename "$BS3_PATCH")"
fi

( cd "$WORK/bs3" && CC="$CC" CXX="$CXX" npx --yes node-gyp rebuild --release \
    --runtime=electron --target="$EL_VER" --arch=x64 \
    --dist-url=https://electronjs.org/headers ) >"$WORK/build.log" 2>&1 \
  || { tail -30 "$WORK/build.log"; die "native build failed (full log: $WORK/build.log)"; }

cp "$WORK/bs3/build/Release/better_sqlite3.node" \
   "$WORK/bs3/build/Release/test_extension.node" "$BS3/build/Release/"


step "Setting up the Chromium sandbox"

# Ubuntu 23.10+ blocks unprivileged user namespaces through AppArmor, so
# Electron falls back to the setuid chrome-sandbox helper and aborts at launch
# unless that helper is root-owned with mode 4755.
if [[ "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null)" == 1 ]]; then
  info "unprivileged user namespaces are restricted; chrome-sandbox needs to be setuid root (sudo)"
  sudo chown root:root "$INSTALL_DIR/chrome-sandbox" && sudo chmod 4755 "$INSTALL_DIR/chrome-sandbox" \
    || die "could not set up chrome-sandbox. Run: sudo chown root:root $INSTALL_DIR/chrome-sandbox && sudo chmod 4755 $INSTALL_DIR/chrome-sandbox"
else
  info "user namespaces available, nothing to do"
fi


step "Installing launcher and desktop entry"

cat > "$INSTALL_DIR/granola.sh" <<EOF
#!/usr/bin/env bash
DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
# Native Wayland segfaults on startup (Electron 44 / Granola 7.668), so run
# through XWayland. Harmless on X11 sessions.
exec "\$DIR/electron" --ozone-platform=x11 "\$@"
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
