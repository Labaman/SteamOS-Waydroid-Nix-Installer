#!/usr/bin/env bash
# System part of targets.genericLinux.gpu on SteamOS (idempotent).
# Run once after the first `home-manager switch`, and again whenever switch warns
# "GPU drivers require an update".
set -euo pipefail

SETUP="$HOME/.nix-profile/bin/non-nixos-gpu-setup"
KEEP_CONF=/etc/atomic-update.conf.d/non-nixos-gpu.conf

ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
skip() { printf '\033[33m→\033[0m %s (already done)\n' "$*"; }
die()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

[[ -x "$SETUP" ]] || die "non-nixos-gpu-setup not found — run home-manager switch first"

# non-nixos-gpu-setup installs /etc/tmpfiles.d/non-nixos-gpu.conf (a symlink into the
# store); systemd-tmpfiles uses it to create /run/opengl-driver on every boot. It is
# idempotent (ln -sf), so always run it — this also picks up new drivers.
# Absolute store path for sudo: sudo does not keep the user's PATH.
sudo "$(readlink -f "$SETUP")"
ok "/run/opengl-driver → $(readlink /run/opengl-driver)"

# A SteamOS (RAUC) update wipes the /etc overlay except for paths in the keep-list.
# /etc/tmpfiles.d/ is not in the base list — without this entry /run/opengl-driver is
# gone after an update and Nix GUI apps lose the GPU. nix-installer does the same for
# its own /etc/tmpfiles.d/nix-daemon.conf.
KEEP_LINE=/etc/tmpfiles.d/non-nixos-gpu.conf
if [[ "$(cat "$KEEP_CONF" 2>/dev/null)" == "$KEEP_LINE" ]]; then
  skip "$KEEP_CONF"
else
  printf '%s\n' "$KEEP_LINE" | sudo install -D -m 644 /dev/stdin "$KEEP_CONF"
  ok "Wrote $KEEP_CONF"
fi
