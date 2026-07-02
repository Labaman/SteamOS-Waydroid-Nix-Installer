{ config, lib, pkgs, nixgl, ... }:

# Home Manager config for Steam Deck (SteamOS, non-NixOS) with Waydroid.
# Solves SteamDeck-specific issues and installs Android via Waydroid in LXC.

let
  # Keep Flatpak first (set by /etc/profile -> flatpak.sh), append Nix+system.
  xdgDataDirsAppend =
    "\${XDG_DATA_DIRS:+\$XDG_DATA_DIRS:}${lib.concatStringsSep ":" config.xdg.systemDirs.data}";

  # POSIX dedup, keep-first, order preserved (works in zsh/bash and fish via babelfish).
  dedupXdgDataDirs = ''
    XDG_DATA_DIRS="$(printf '%s' "$XDG_DATA_DIRS" | awk -v RS=: -v ORS=: '!a[$0]++' | sed 's/:$//')"
    export XDG_DATA_DIRS
  '';
in
{
  home.username = "deck";
  home.homeDirectory = "/home/deck";
  home.stateVersion = "26.05";

  # Required on non-NixOS.
  targets.genericLinux.enable = true;
  xdg.enable = true;

  # nixGL: GPU drivers for Nix GUI apps (Deck = AMD). mesa = OpenGL, vulkan = RADV.
  # Use: home.packages = [ (config.lib.nixGL.wrap pkgs.<app>) ];  or  nixGLMesa <app>
  targets.genericLinux.nixGL = {
    packages = nixgl.packages;
    defaultWrapper = "mesa";
    vulkan.enable = true;
    installScripts = [ "mesa" ];
  };

  # Example: browser wrapped with nixGL via the programs.chromium HM module.
  # The module generates a proper .desktop entry and handles XDG mime types;
  # nixGL.wrap injects the host GPU drivers so the app can render on the Deck.
  # Swap pkgs.google-chrome for pkgs.brave / pkgs.chromium / pkgs.ungoogled-chromium etc.
  # programs.chromium = {
  #   enable = true;
  #   package = config.lib.nixGL.wrap pkgs.google-chrome;
  #   commandLineArgs = [
  #     "--enable-features=VaapiIgnoreDriverChecks,AcceleratedVideoEncoder,ParallelDownloading"
  #     "--ignore-gpu-blocklist"
  #   ];
  # };

  # XDG_DATA_DIRS order fix: keep Flatpak ahead of the SteamOS "Install Firefox"
  # stub in the KDE menu (HM #8076 / #9356). Overrides prepend -> append.
  home.sessionVariables.XDG_DATA_DIRS = lib.mkForce xdgDataDirsAppend;
  systemd.user.sessionVariables.XDG_DATA_DIRS = lib.mkForce xdgDataDirsAppend;
  # Dedup for all shells via hm-session-vars.sh (zsh, bash, fish via babelfish).
  home.sessionVariablesExtra = lib.mkAfter dedupXdgDataDirs;
  # bash only (genericLinux re-sources nix.sh in .bashrc after the guard) — may be
  # removed when using zsh or fish.
  programs.bash.initExtra = lib.mkAfter dedupXdgDataDirs;

  # After switch, system apps (Konsole etc.) vanish from the KDE launcher and search.
  # Home Manager's activation script overrides PATH to a bare list of Nix store tools —
  # /usr/bin isn't included, so kbuildsycoca6 silently builds an incomplete cache missing
  # system apps. Fix: prepend /usr/bin to PATH before calling it.
  # env -u LD_LIBRARY_PATH avoids a glibc conflict with Nix's own glibc.
  home.activation.refreshPlasmaMenu =
    lib.hm.dag.entryAfter [ "linkGeneration" "onFilesChange" ] ''
      if [ -x /usr/bin/kbuildsycoca6 ]; then
        $DRY_RUN_CMD env -u LD_LIBRARY_PATH PATH="/usr/bin:/usr/local/bin:$PATH" /usr/bin/kbuildsycoca6 --noincremental || true
      fi
    '';

  # Native Wayland for Nix GUI apps (SteamOS 3.8).
  home.sessionVariables = {
    NIXOS_OZONE_WL = "1";
    QT_QPA_PLATFORM = "wayland;xcb";
  };

  # bash only: pushes Wayland vars to KDE-launched apps via plasma-workspace/env,
  # since bash misses the non-interactive non-login startup path. Inert for zsh/fish
  # (guarded by lib.mkIf) — may be removed when switching to zsh or fish.
  home.file.".config/plasma-workspace/env/nixos-ozone-wl.sh" =
    lib.mkIf config.programs.bash.enable {
      text = ''
        export NIXOS_OZONE_WL=1
        export QT_QPA_PLATFORM="wayland;xcb"
      '';
    };

  # ── Shell (required — uncomment ONE) ─────────────────────────────────────────
  # See README for shell comparison, advantages of zsh/fish, and how to change the
  # default login shell.
  #
  # programs.bash.enable = true;
  #
  # programs.zsh = {
  #   enable = true;
  #   enableCompletion = true;
  #   autosuggestion.enable = true;
  #   syntaxHighlighting.enable = true;
  #   defaultKeymap = "emacs";
  # };
  #
  # programs.fish.enable = true;

  # ~/.local/bin in PATH: pip, cargo, and official installers put binaries there.
  # Also required for waydroid-setup and waydroid-gamemode scripts below.
  home.sessionPath = [ "$HOME/.local/bin" ];

  # Starship prompt — shell-independent (same toml renders in bash, zsh, and fish).
  # Matches the default SteamOS bash style 1:1 (__steamos_prompt_command in
  # /etc/bash.bashrc): (rc)(user@host dir)$ — rc in red only on a non-zero exit
  # code, user@host as one green block, parens (not square brackets). Git
  # branch/status is our own addition — the original bash prompt has no git info:
  #   (deck@steamdeck ~)$                outside a repo
  #   (deck@steamdeck myapp) [main]$     inside a repo
  programs.starship = {
    enable = true;
    settings = {
      format = "$status\\($username$hostname $directory\\)( \\[$git_branch$git_status\\])$character ";
      add_newline = false;

      status = {
        disabled = false;
        style = "bold red";
        format = "[($status)]($style)";
      };

      username = {
        show_always = true;
        style_user = "bold green";
        style_root = "bold red";
        format = "[$user@]($style)";
      };

      hostname = {
        ssh_only = false;
        style = "bold green";
        format = "[$hostname]($style)";
      };

      directory = {
        style = "bold blue";
        truncation_length = 1;
        truncate_to_repo = false;
        format = "[$path]($style)";
      };

      git_branch = {
        format = "[$branch]($style)";
        style = "bold yellow";
      };

      git_status = {
        format = "[$all_status]($style)";
        style = "bold red";
        modified   = "*";
        staged     = "+";
        untracked  = "?";
        deleted    = "*";
        renamed    = "";
        conflicted = "!";
        stashed    = "";
        ahead      = "⇡";
        behind     = "⇣";
        diverged   = "⇕";
        up_to_date = "";
      };

      character = {
        success_symbol = "[\\$](bold white)";
        error_symbol   = "[\\$](bold red)";
      };
    };
  };

  # ── Waydroid: Android in an LXC container ────────────────────────────────────
  # After `home-manager switch`, run once to complete the setup:
  #   waydroid-setup
  #
  # Safe to re-run after SteamOS updates — already completed steps are skipped automatically.
  # What Nix/HM covers:   packages below + scripts in ~/.local/bin/
  # What the script does: /etc/systemd, /etc/dbus-1, /etc/gbinder.d, firewalld
  #                       (require root; all survive SteamOS updates via /etc overlay)
  home.packages = [
    pkgs.waydroid-nftables # Waydroid with nftables backend (required on SteamOS)
    pkgs.lxc               # lxc-start — used by waydroid as an external binary

    # Game Mode launcher uses cage (a nested Wayland compositor) because a direct
    # waydroid show-full-ui does not create a gamescope window (same approach as
    # ryanrudolfoba / Bazzite).
    (config.lib.nixGL.wrap pkgs.cage) # cage renders on GPU → needs nixGL wrapper
    pkgs.wlr-randr                    # sets output resolution inside cage

    # Add your own packages here, e.g.:
    # pkgs.ripgrep
    # pkgs.fd
  ];

  # Setup script — run once after switch; safe to re-run.
  home.file.".local/bin/waydroid-setup" = {
    executable = true;
    source = ./scripts/waydroid-setup.sh;
  };

  # Game Mode launcher — add to Steam as a non-Steam game:
  #   Games → Add a Non-Steam Game → Browse → ~/.local/bin/waydroid-gamemode
  home.file.".local/bin/waydroid-gamemode" = {
    executable = true;
    source = ./scripts/waydroid-gamemode.sh;
  };

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  # Uncomment to manage git. Activates ensureMutableGitconfig below automatically.
  # programs.git = {
  #   enable = true;
  #   settings.user = {
  #     name  = "Your Name";
  #     email = "you@example.com";
  #   };
  # };

  # programs.git makes ~/.config/git/config a read-only symlink into the Nix store.
  # Tools that call `git config --global` during setup (EmuDeck, rustup, etc.) fail with
  # "could not lock config file ... Permission denied". Git writes --global to ~/.gitconfig
  # when that file exists, falling back to the XDG path otherwise. Ensuring a writable
  # ~/.gitconfig redirects those writes there; the managed config remains read-only
  # and is still read by git (it checks both files).
  home.activation.ensureMutableGitconfig = lib.mkIf config.programs.git.enable
    (lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ ! -e "$HOME/.gitconfig" ]; then
        $DRY_RUN_CMD touch "$HOME/.gitconfig"
      fi
    '');
}
