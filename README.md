# SteamOS-Waydroid-Nix-Installer

**English** | [Русский](README.ru.md)

Installs [Waydroid](https://waydroid.io/) (Android 13 + GAPPS) on Steam Deck via Nix + Home Manager.

Does everything [nix-hm-conf-steamdeck](https://github.com/Labaman/nix-hm-conf-steamdeck) does — base SteamOS fixes, nixGL, shell prompt, Wayland — plus installs Android in an LXC container with a Game Mode launcher and gamepad support.

Supports SteamOS 3.5 through 3.8. Packages and settings survive SteamOS updates.

## Features

| Feature | Notes |
|---------|-------|
| Base SteamOS fixes | See [nix-hm-conf-steamdeck](https://github.com/Labaman/nix-hm-conf-steamdeck) for details |
| Waydroid | Android 13 + GAPPS in an LXC container |
| Game Mode launcher | `waydroid-gamemode` — add to Steam as a non-Steam game |
| Gamepad support | Right stick mapped correctly for Android games |
| ARM translation | libhoudini via [casualsnek/waydroid_script](https://github.com/casualsnek/waydroid_script) |

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

The script is idempotent — safe to re-run after SteamOS A/B updates.

Add your own packages and programs inside `home.nix`.

## Waydroid Game Mode

After `waydroid-setup` completes, add Waydroid to Steam:

**Desktop Mode** → Games → Add a Non-Steam Game → Browse → `~/.local/bin/waydroid-gamemode` → rename to "Waydroid"

## Shell (optional)

A managed shell is required to source session variables into the graphical session.
Uncomment one of the shell blocks in `home.nix`.

| Shell | Session env coverage | Notes |
|-------|----------------------|-------|
| **bash** | login + interactive shells | SteamOS default; simplest to start with. The two `# bash only` entries in `home.nix` cover the non-interactive startup gap. |
| **zsh** | login, interactive & non-interactive | `.zshenv` is sourced for every zsh invocation, so session vars always load without any workarounds. Does not touch bash dotfiles. The `# bash only` entries in `home.nix` may be removed. |
| **fish** | login, interactive & non-interactive | Autocompletion, command suggestions, and syntax highlighting work out of the box without extra config. Does not touch bash dotfiles. The `# bash only` entries may be removed. Note: fish syntax is not POSIX/bash-compatible — bash scripts won't run directly inside fish. |

### Changing the default login shell

Switching from the default bash to zsh or fish is recommended — their HM modules are more actively developed, and the bash-specific workarounds become unnecessary.

To use zsh or fish, switch to the **system-provided** binary — not the Nix-managed one.
This keeps login working even if Nix is later removed (both shells ship with SteamOS):

Switch to **zsh**:
```bash
chsh -s /usr/bin/zsh
```

Switch to **fish**:
```bash
chsh -s /usr/bin/fish
```

Do this **before** running `home-manager switch` with the shell module enabled.
After re-login, uncomment the corresponding shell block in `home.nix`.
