# Granola on Linux

[Granola](https://www.granola.ai) only ships for macOS and Windows. It is an Electron app though, so the macOS `.dmg` already holds all of the app's JavaScript, which runs anywhere. It is just attached to a macOS runtime. This repo swaps in the Linux runtime and fixes what breaks. You get a real Linux app. No Wine, no VM, no emulation.

![Granola running on Linux](docs/screenshot.png)

## Arch / Omarchy

This is a pacman package. It pulls the official macOS `.dmg`, swaps in Linux Electron, and installs to `/usr/lib/granola`.

```bash
cd packaging/arch
makepkg -si
```

Launch from the app menu (Omarchy: Super+Space, type Granola). Remove with `sudo pacman -Rns granola`.

There is also an AUR package of the same name, built the same way. On Omarchy: `omarchy pkg aur add granola`. It can lag a release behind this repo.

## Other distros

1. Download the `.dmg` from [granola.ai/download](https://www.granola.ai/download)
2. Install what you need:
   - Debian/Ubuntu: `sudo apt install g++-11 nodejs npm python3 curl make`
   - Fedora: `sudo dnf install gcc-c++ make nodejs npm python3 curl`
3. Run `./granola-linux.sh "Granola - AI Notepad.dmg"`
4. Open Granola from your app menu and sign in

The script installs to `~/Applications/granola`, adds a desktop entry, registers the `granola://` sign-in handler, and tests the build before it tells you it worked. Run `./uninstall.sh` to undo it. Set `INSTALL_DIR=` to install somewhere else. You need x86-64 and g++ 11 or newer.

If your distro packages a modern `7zz` (Arch's `7zip`, for example), the script uses it and skips the download from 7-zip.org. Only `p7zip`-era builds are too old — see step 1 under *Build it yourself*.

The launcher asks Electron for Wayland when the session is Wayland, and turns on PipeWire capture so the in-app meeting picker can see screens and system audio through `xdg-desktop-portal`. On Hyprland/Omarchy that portal is already there.

Tested on:

| Distro | Granola | Electron |
|---|---|---|
| Pop!\_OS (Ubuntu 20.04 base, glibc 2.32) | 7.452.1 | 42.7.0 |
| Omarchy (Arch, glibc 2.44, gcc 16, electron44 44.3.0) | 7.568.0 | 44.3.0 |

## What works

| | |
|---|---|
| ✅ | Notes, editor, sync, AI features, and search. The core app. |
| ✅ | Sign-in with Google, Microsoft, or SSO |
| ✅ | Encrypted local database that survives restarts |
| ✅ | Microphone recording |
| ⚠️ | System audio capture is limited. The macOS build uses Core Audio to hear the other side of a call. On Linux the app falls back to a browser style capture path. |
| ❌ | Apple Calendar (EventKit). Google and Microsoft calendars still work, since those run on the server. |
| ❌ | Global hotkeys |
| ❌ | Auto-update. Run the script again with a newer `.dmg`. |

## Build it yourself

If you would rather not run the script, the conversion takes six steps:

1. Extract the `.dmg` with a modern `7zz`. The `p7zip` in most distros cannot read its LZFSE compression.
2. Read the Electron version out of `Electron Framework.framework/.../Info.plist`, then download that exact Linux build.
3. Unzip the Linux runtime into your install folder and delete `resources/default_app.asar`.
4. Copy `app.asar`, `app.asar.unpacked`, and `icons/` from the bundle into the runtime's `resources/`. Skip every Mac binary, since they all sit behind `darwin` checks.
5. Patch the platform string inside `app.asar` so it reports `Windows`. Granola's API returns a 500 error for `platform=linux`, so sign-in fails without this.
6. Rebuild `better-sqlite3-multiple-ciphers` from the C++ source inside `app.asar.unpacked` using g++ 11 or newer. Granola's version adds an `updateHook()` that no public build has.

Four of those six fail with errors that do not point at the real cause. `granola-linux.sh` has the exact commands, with comments explaining each one.

## Notes

- Nothing here gets around licensing or sign-in. You use your own account and the app talks to Granola's real servers. The only patch is a platform label that their API refuses to accept.
- Granola's code belongs to Granola. Do not commit `app.asar` or the `.dmg`. The `.gitignore` covers both.
- Running the script again is safe. It wipes and rebuilds the install folder and leaves your notes in `~/.config/Granola` alone.
- `./uninstall.sh --purge` also removes the local notes cache and login.
