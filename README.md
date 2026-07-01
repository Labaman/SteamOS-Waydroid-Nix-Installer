# SteamOS-Waydroid-Nix-Installer

**English** | [Русский](README.ru.md)

Installs [Waydroid](https://waydroid.io/) (Android 13 + GAPPS) on Steam Deck via Nix + Home Manager.

Does everything [nix-hm-conf-steamdeck](https://github.com/Labaman/nix-hm-conf-steamdeck) does — base SteamOS fixes, nixGL, shell prompt, Wayland — plus installs Android in an LXC container with a Game Mode launcher and gamepad support.

Packages and settings survive SteamOS updates.

## Features

| Feature | Notes |
|---------|-------|
| Base SteamOS fixes | See [nix-hm-conf-steamdeck](https://github.com/Labaman/nix-hm-conf-steamdeck) for details |
| Waydroid | Android 13 + GAPPS in an LXC container |
| Game Mode launcher | `waydroid-gamemode` — add to Steam as a non-Steam game |
| Gamepad support | Right stick mapped correctly for Android games |
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
home-manager switch --flake ~/.config/home-manager#deck
```

Then run the Waydroid setup script once (~3 GB download for the Android image):

```bash
waydroid-setup
```

Safe to re-run after SteamOS updates — already completed steps are skipped automatically.

Add your own packages and programs inside `home.nix`.

## Waydroid Game Mode

After `waydroid-setup` completes, add Waydroid to Steam:

**Desktop Mode** → Games → Add a Non-Steam Game → Browse → `~/.local/bin/waydroid-gamemode` → rename to "Waydroid"

## Shell (optional)

Uncomment one shell block in `home.nix` (`bash`, `zsh`, or `fish`) to enable the Starship prompt and ensure session variables reach GUI apps.
See [nix-hm-conf-steamdeck](https://github.com/Labaman/nix-hm-conf-steamdeck) for a full shell comparison and login-shell change instructions.

## Credits

- [ryanrudolfoba/SteamOS-Waydroid-Installer](https://github.com/ryanrudolfoba/SteamOS-Waydroid-Installer) — Game Mode cage launcher approach and `waydroid_base.prop` udev/uevent props
- [Bazzite](https://github.com/ublue-os/bazzite) — uevent retrigger pattern for gamepad support
- [casualsnek/waydroid_script](https://github.com/casualsnek/waydroid_script) — libhoudini ARM translation installer
