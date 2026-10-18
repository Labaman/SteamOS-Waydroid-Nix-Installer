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
| Game Mode launcher | `waydroid-gamemode` lets you add Waydroid to Steam as a non-Steam game |
| Gamepad support | Right stick mapped correctly for Android games; gamepads connected before the session starts are picked up automatically (Game Mode and Desktop Mode) |
| Binder module | SteamOS kernels since 6.18 ship without binder — `waydroid-setup` builds the kernel's own in-tree binder for the running kernel (sources from kernel.org + a small kallsyms shim, no driver patches); skipped if the kernel has binder built in |
| ARM translation | libhoudini via [casualsnek/waydroid_script](https://github.com/casualsnek/waydroid_script) |

## Requirements

- SteamOS 3.5 or newer
- ~3 GB free space on internal storage for the Android image

## Usage

If Nix isn't installed yet, install it. The official installer [NixOS/nix-installer](https://github.com/NixOS/nix-installer) is recommended: it detects SteamOS automatically and handles the initial setup:

```bash
curl -sSfL https://artifacts.nixos.org/nix-installer | sh -s -- install --enable-flakes
```

Then:

```bash
git clone https://github.com/Labaman/SteamOS-Waydroid-Nix-Installer ~/.config/home-manager
nix run home-manager/master -- switch
```

The first run takes Home Manager straight from GitHub via `nix run` — no separate install needed. After that the `home-manager` command is in your profile, so later runs are just `home-manager switch`.

If a config file that Home Manager needs to manage already exists (for example, `~/.bashrc` when you enable bash), it gets renamed to `<file>.hm-backup`. If that backup already exists, `switch` stops: delete or rename the old backup and run it again.

Then open a new terminal window: the current one was started before `switch`, so `~/.local/bin` (where `nix-gpu-setup` and `waydroid-setup` are installed) isn't in its `PATH` yet.

Set up GPU drivers for Nix GUI apps (asks for the sudo password; re-run it when `switch` warns that GPU drivers require an update):

```bash
nix-gpu-setup
```

Then run the Waydroid setup script once (~3 GB download for the Android image):

```bash
waydroid-setup
```

Re-run `waydroid-setup` after every SteamOS or Waydroid image update: steps that are already done are skipped, and anything the update overwrote is restored.

Add your own packages and programs to `home.nix`, below the `# Add your own packages here` comment.

## Waydroid Game Mode

After `waydroid-setup` completes, add Waydroid to Steam:

**Desktop Mode** → Games → Add a Non-Steam Game → Browse → `~/.local/bin/waydroid-gamemode` → rename to "Waydroid"

Then turn on native touchscreen support in the controller settings of the Waydroid shortcut:

Edit Layout → Action Sets → Default → Add Always-On command → System → Touchscreen Native Support

## Shell

Home Manager writes session variables (including `~/.local/bin` in `PATH`, where `waydroid-setup` lives) to `hm-session-vars.sh`, which only a Home Manager-managed shell loads. The SteamOS login shell is bash, so `programs.bash` is enabled in `home.nix` by default. Your existing `~/.bashrc` and `~/.bash_profile` are renamed to `*.hm-backup`.
To use zsh or fish instead, see [nix-hm-conf-steamos](https://github.com/Labaman/nix-hm-conf-steamos).

## Updating & maintenance

Updating packages, cleaning up old generations and uninstalling Home Manager and Nix work the same way as in [nix-hm-conf-steamos](https://github.com/Labaman/nix-hm-conf-steamos#updating--maintenance).

To remove Waydroid itself — Android with all its data and everything `waydroid-setup` added to the system — run this before removing Home Manager and Nix (add `--dry-run` to see what would be removed):

```bash
waydroid-setup --uninstall
```

## Credits

- SteamOS-Waydroid-Installer by [ryanrudolfoba](https://github.com/ryanrudolfoba) (the original repository is no longer available) — Game Mode cage launcher approach and `waydroid_base.prop` udev/uevent props
- [Bazzite](https://github.com/ublue-os/bazzite) — uevent retrigger pattern for gamepad support
- [casualsnek/waydroid_script](https://github.com/casualsnek/waydroid_script) — libhoudini ARM translation installer
- Linux kernel `drivers/android` — GPL-2.0 — in-tree binder; sources fetched at build time from kernel.org for the running kernel version
- The Android Open Source Project — the right-stick key layout (Apache-2.0)

## License

Licensed under the **GNU General Public License v3.0 or later** (GPL-3.0-or-later) — see [LICENSE](LICENSE).

Third-party attributions are in [NOTICE](NOTICE). Runtime dependencies (Waydroid, waydroid_script, ARM translators) are fetched or invoked at install time and keep their own licenses — they are not bundled in this repository.
