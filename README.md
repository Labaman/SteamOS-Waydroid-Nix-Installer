# SteamOS Waydroid Nix Installer

**English** | [Русский](README.ru.md)

> [!WARNING]
> Starting with SteamOS 3.8.28 (the linux-neptune-618 kernel), SteamOS ships without
> the Android binder driver (`CONFIG_ANDROID_BINDER_IPC` is disabled), which Waydroid
> needs. This installer builds binder for the running kernel from the kernel's own
> upstream sources as a loadable module, so Waydroid works today — but the proper fix
> is for Valve to re-enable binder in the SteamOS kernel.
>
> 👉 Please upvote / subscribe to the issue:
> [ValveSoftware/SteamOS#2848](https://github.com/ValveSoftware/SteamOS/issues/2848).

Installs [Waydroid](https://waydro.id) (Android 13 + GAPPS) on SteamOS via Nix + Home Manager.

Does everything [nix-hm-conf-steamos](https://github.com/Labaman/nix-hm-conf-steamos) does — base SteamOS fixes, GPU drivers for Nix GUI apps, shell prompt, native Wayland for Nix GUI apps (Electron/Chromium + Qt) — plus installs Android in an LXC container with a Game Mode launcher and gamepad support.

Packages and settings survive SteamOS updates.

## Features

| Feature | Notes |
|---------|-------|
| Base SteamOS fixes | See [nix-hm-conf-steamos](https://github.com/Labaman/nix-hm-conf-steamos) for details |
| Waydroid | Android 13 + GAPPS in an LXC container |
| Game Mode launcher | `waydroid-gamemode` — add to Steam as a non-Steam game |
| Gamepad support | Right stick mapped correctly for Android games |
| Binder module | SteamOS kernels since 6.18 ship without binder — `waydroid-setup` builds the kernel's own in-tree binder for the running kernel (sources from kernel.org + a small kallsyms shim, no driver patches); skipped if the kernel has binder built in |
| ARM translation | libhoudini via [casualsnek/waydroid_script](https://github.com/casualsnek/waydroid_script) |

## Requirements

- SteamOS 3.5 or newer
- ~3 GB free space on internal storage for the Android image

## Usage

Install Nix if not already installed ([NixOS/nix-installer](https://github.com/NixOS/nix-installer), auto-detects SteamOS):

```bash
curl -sSfL https://artifacts.nixos.org/nix-installer | sh -s -- install --enable-flakes
```

Clone and apply:

```bash
git clone https://github.com/Labaman/SteamOS-Waydroid-Nix-Installer ~/.config/home-manager
nix run home-manager/master -- switch
```

The first run takes Home Manager straight from GitHub via `nix run` — no separate install needed. After that the `home-manager` command is in your profile, so later runs are just `home-manager switch`.

Set up GPU drivers for Nix GUI apps (asks for the sudo password; re-run it when `switch` warns that GPU drivers require an update):

```bash
nix-gpu-setup
```

Then run the Waydroid setup script once (~3 GB download for the Android image):

```bash
waydroid-setup
```

Safe to re-run after SteamOS updates — already completed steps are skipped automatically. Re-run it after every SteamOS update that changes the kernel: it rebuilds the binder module for the new kernel, otherwise `waydroid-container.service` won't start.

Add your own packages and programs inside `home.nix`.

## Waydroid Game Mode

After `waydroid-setup` completes, add Waydroid to Steam:

**Desktop Mode** → Games → Add a Non-Steam Game → Browse → `~/.local/bin/waydroid-gamemode` → rename to "Waydroid"

## Shell (optional)

Uncomment one shell block in `home.nix` (`bash`, `zsh`, or `fish`) to enable the Starship prompt and ensure session variables reach GUI apps.
See [nix-hm-conf-steamos](https://github.com/Labaman/nix-hm-conf-steamos) for a full shell comparison and login-shell change instructions.

## Credits

- [ryanrudolfoba/SteamOS-Waydroid-Installer](https://github.com/ryanrudolfoba/SteamOS-Waydroid-Installer) — Game Mode cage launcher approach and `waydroid_base.prop` udev/uevent props
- [Bazzite](https://github.com/ublue-os/bazzite) — uevent retrigger pattern for gamepad support
- [casualsnek/waydroid_script](https://github.com/casualsnek/waydroid_script) — libhoudini ARM translation installer
- Linux kernel `drivers/android` — GPL-2.0 — in-tree binder; sources fetched at build time from kernel.org for the running kernel version
- The Android Open Source Project — the right-stick key layout (Apache-2.0)

## License

Licensed under the **GNU General Public License v3.0 or later** (GPL-3.0-or-later) — see [LICENSE](LICENSE).

Third-party attributions are in [NOTICE](NOTICE). Runtime dependencies (Waydroid, waydroid_script, ARM translators) are fetched or invoked at install time and keep their own licenses — they are not bundled in this repository.
