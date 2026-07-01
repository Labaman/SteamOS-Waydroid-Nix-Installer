#!/usr/bin/env bash
# Waydroid installer for SteamOS
# Run: waydroid-setup
set -euo pipefail

NIX_BIN="$HOME/.nix-profile/bin"
WAYDROID_BIN="$NIX_BIN/waydroid"
WAYDROID_DATA="$HOME/.local/share/waydroid"
SCRIPT_DIR="$HOME/waydroid_script"

ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
skip() { printf '\033[33m→\033[0m %s (already done)\n' "$*"; }
step() { printf '\n\033[1;34m══ %s ══\033[0m\n' "$*"; }
die()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# Writes a file to /etc only if the content has changed.
# Returns 0 (written) / 1 (unchanged).
# install -D -m 644 (not mkdir+cp): mktemp creates tmp with 600 permissions, and a
# plain cp would copy the source's permissions as-is → the file in /etc ends up
# root-only. Daemons like dbus-broker don't run as root (they run as the system
# dbus user) and can't read such a file — this is exactly how the
# id.waydro.Container.conf policy silently stopped being applied.
write_etc() {
  local dest="$1"
  local tmp; tmp=$(mktemp)
  cat > "$tmp"
  # Check both content AND permissions: files already written by the OLD version
  # of this function (before the mktemp→600 fix) match on content but are still
  # root-only — a content-only cmp isn't enough, or such files would stay
  # unreadable to non-root daemons (dbus-broker etc.) forever.
  if sudo test -f "$dest" && sudo cmp -s "$tmp" "$dest" 2>/dev/null \
     && [[ "$(sudo stat -c %a "$dest" 2>/dev/null)" == "644" ]]; then
    skip "$dest"; rm -f "$tmp"; return 1
  fi
  sudo install -D -m 644 "$tmp" "$dest"
  rm -f "$tmp"
  ok "Written $dest"
}

# Waits until waydroid-container.service actually comes up. The unit is
# Type=dbus — is-active only becomes true once the process has acquired its
# BusName, so this is a genuine readiness check, not just "the process hasn't
# crashed yet". Fails clearly with a helpful pointer instead of silently
# continuing with a broken service.
ensure_container_active() {
  local tries=0
  until systemctl is-active --quiet waydroid-container.service; do
    tries=$((tries + 1))
    if (( tries >= 15 )); then
      die "waydroid-container.service failed to come up — check: journalctl -xeu waydroid-container.service"
    fi
    sleep 1
  done
}

# ── 1. Check dependencies ─────────────────────────────────────────────────
step "1/7  Check dependencies"
[[ -x "$WAYDROID_BIN" ]]       || die "waydroid not found — run: home-manager switch"
[[ -x "$NIX_BIN/lxc-start" ]] || die "lxc not found — run: home-manager switch"
ok "waydroid and lxc found"

# ── 2. /etc files (overlay → /var → survive SteamOS updates) ─────────────
step "2/7  /etc configs (systemd, D-Bus, gbinder)"

RELOAD_SYSTEMD=false
RELOAD_DBUS=false

if write_etc /etc/systemd/system/waydroid-container.service <<UNIT
[Unit]
Description=Waydroid Container
After=network.target dbus.service

[Service]
Type=dbus
BusName=id.waydro.Container
Environment=PATH=$NIX_BIN:/usr/bin:/bin
ExecStart=$WAYDROID_BIN container start
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
then RELOAD_SYSTEMD=true; fi

if write_etc /etc/dbus-1/system.d/id.waydro.Container.conf <<DBUS
<?xml version="1.0"?>
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <policy user="root">
    <allow own="id.waydro.Container"/>
  </policy>
  <policy context="default">
    <allow send_destination="id.waydro.Container"/>
    <allow receive_sender="id.waydro.Container"/>
  </policy>
</busconfig>
DBUS
then RELOAD_DBUS=true; fi

RELOAD_GBINDER=false
if write_etc /etc/gbinder.d/waydroid.conf <<GBINDER
[Protocol]
/dev/anbox-binder = aidl2
/dev/anbox-vndbinder = aidl2
/dev/anbox-hwbinder = hidl

[ServiceManager]
/dev/anbox-binder = aidl2
/dev/anbox-vndbinder = aidl2
/dev/anbox-hwbinder = hidl
GBINDER
then RELOAD_GBINDER=true; fi

$RELOAD_SYSTEMD && { sudo systemctl daemon-reload; ok "daemon-reload"; }
$RELOAD_DBUS    && { sudo systemctl reload dbus.service; ok "D-Bus reloaded"; }

# systemd/dbus configs apply live (daemon-reload / reload are wired to
# SIGHUP+notify-reload, no restart needed). But the container process itself
# only reads gbinder.conf and the BusName policy at its OWN startup — if it was
# already running (e.g. after a previous install and a host reboot), it won't
# see the new config without a restart. Restart once if any of the three
# changed AND the container is already active; if nothing changed, move on
# quietly. A host reboot is never required for any of these files.
if { $RELOAD_SYSTEMD || $RELOAD_DBUS || $RELOAD_GBINDER; } && systemctl is-active --quiet waydroid-container.service; then
  sudo systemctl restart waydroid-container.service
  ensure_container_active
  ok "waydroid-container.service restarted (picking up new config)"
fi

# ── 3. Android data: directory + symlink ──────────────────────────────────
step "3/7  Data directory and /var/lib/waydroid symlink"
mkdir -p "$WAYDROID_DATA"

if [[ "$(readlink /var/lib/waydroid 2>/dev/null)" == "$WAYDROID_DATA" ]]; then
  skip "/var/lib/waydroid → $WAYDROID_DATA"
else
  sudo rm -rf /var/lib/waydroid
  sudo ln -sf "$WAYDROID_DATA" /var/lib/waydroid
  ok "Symlink /var/lib/waydroid → $WAYDROID_DATA"
fi

# ── 4. waydroid init ──────────────────────────────────────────────────────
step "4/7  waydroid init (Android 13 + GAPPS, ~3 GB)"
if [[ -f "$WAYDROID_DATA/images/system.img" ]]; then
  skip "Android images already downloaded"
else
  sudo PATH="$NIX_BIN:$PATH" "$WAYDROID_BIN" init -s GAPPS
  ok "waydroid init complete"
fi

if [[ "$(stat -c %U "$WAYDROID_DATA")" != "$(whoami)" ]]; then
  sudo chown "$(whoami):$(whoami)" "$WAYDROID_DATA"
  ok "chown $(whoami) $WAYDROID_DATA"
else
  skip "$WAYDROID_DATA owner already correct"
fi

# Gamepad: Android only detects input devices (including gamepads) when Waydroid
# forwards udev/uevent events to the container — enabled by these props. Appended to
# base.prop (not overwritten — GPU/libhoudini props from init are already there).
# Source: ryanrudolfoba/extras/waydroid_base.prop. Applied on session start.
for prop in persist.waydroid.udev=true persist.waydroid.uevent=true; do
  if grep -qxF "$prop" "$WAYDROID_DATA/waydroid_base.prop" 2>/dev/null; then
    skip "prop $prop"
  else
    echo "$prop" | sudo tee -a "$WAYDROID_DATA/waydroid_base.prop" >/dev/null
    ok "prop $prop → waydroid_base.prop"
  fi
done

# Right stick: Steam creates a virtual gamepad vendor=0x28de product=0x11ff (Valve).
# Android looks for Vendor_28de_Product_11ff.kl — not found → falls back to Generic.kl,
# which maps ABS_RX→AXIS_RX, ABS_RY→AXIS_RY. Most games expect the right stick on
# AXIS_Z/AXIS_RZ (like a real Xbox 360, Vendor_045e_Product_028e.kl).
# Bazzite uses overlay; our overlay is disabled (case-folding ext4 on /home) →
# write kl directly into system.img.
KL_PATH="system/usr/keylayout/Vendor_28de_Product_11ff.kl"
# Content mirrors Vendor_045e_Product_028e.kl (Xbox 360).
# ABS_RX(0x03)→Z, ABS_RY(0x04)→RZ — what Android games expect from the right stick.
read -r -d "" KL_CONTENT << 'KLEOF' || true
key 304   BUTTON_A
key 305   BUTTON_B
key 307   BUTTON_X
key 308   BUTTON_Y
key 310   BUTTON_L1
key 311   BUTTON_R1
key 317   BUTTON_THUMBL
key 318   BUTTON_THUMBR
axis 0x00 X flat 4096
axis 0x01 Y flat 4096
axis 0x03 Z flat 4096
axis 0x04 RZ flat 4096
axis 0x02 LTRIGGER
axis 0x05 RTRIGGER
axis 0x10 HAT_X
axis 0x11 HAT_Y
key 314   BUTTON_SELECT
key 316   BUTTON_MODE
key 315   BUTTON_START
KLEOF
# Already-done check: debugfs reads the ext4 image directly without mounting and
# without stopping the container — system.img is mounted inside the lxc
# namespace and isn't accessible via the host rootfs. Checks not just whether
# the file exists, but its SIZE too: if a previous run failed with "no space
# left" right after creating the file but before writing its content, a
# zero-size stub file would remain — "Type: regular" matches that too, and
# without the Size check the script would forever consider this already done.
IMG="$WAYDROID_DATA/images/system.img"
KL_STAT="$(debugfs -R "stat /$KL_PATH" "$IMG" 2>/dev/null)"
# head -1: debugfs prints "Size:" twice — once for the real file size
# (User/Group/Project/Size line), and again on the "Fragment: ... Size: 0" line
# (a legacy ext2 field, always 0). Without head -1 both values got concatenated
# via newline → "392\n0" → arithmetic error in the comparison below.
# || true: on a truly fresh image the path doesn't exist at all (not a
# zero-size stub) → KL_STAT is empty → grep finds no "Size:" → exit 1 →
# set -e silently kills the script right here, with no error printed at all.
# Verified: this isn't about pipes/pipefail — plain `VAR=$(cmd)` under set -e
# reacts to cmd's own exit code, not just to "visible" command failures.
KL_SIZE="$(grep -oE 'Size: [0-9]+' <<<"$KL_STAT" | head -1 | grep -oE '[0-9]+')" || true
if grep -q "Type: regular" <<<"$KL_STAT" && [[ "${KL_SIZE:-0}" -gt 0 ]]; then
  skip "$KL_PATH"
else
  WAS_ACTIVE=false
  if systemctl is-active --quiet waydroid-container.service 2>/dev/null; then
    WAS_ACTIVE=true
    sudo systemctl stop waydroid-container.service && sleep 2
  fi

  # Different LineageOS builds ship with different amounts of free space inside
  # system.img — sometimes it's zero (that's exactly what happened on a fresh
  # reinstall: 2.5G/2.5G, 100%, 0 free blocks). Don't rely on luck for any
  # particular build: count free blocks ahead of time and grow the image
  # idempotently BEFORE attempting the write, instead of reacting to a failed tee.
  FREE_KB="$(dumpe2fs -h "$IMG" 2>/dev/null | awk -F: '
    /Free blocks/ { gsub(/ /,"",$2); free=$2 }
    /Block size/  { gsub(/ /,"",$2); bs=$2 }
    END { if (bs) print free * bs / 1024; else print 0 }')"
  if [[ "${FREE_KB:-0}" -lt 4096 ]]; then
    # e2fsck exit code 1 = "errors corrected" — that's success, not a failure
    # (see man e2fsck).
    sudo e2fsck -fy "$IMG" >/dev/null || true
    sudo truncate -s +32M "$IMG"
    sudo resize2fs "$IMG" >/dev/null
    ok "system.img grown by 32M (had ${FREE_KB:-0}KB free)"
  fi

  TMP_MNT="$(mktemp -d /tmp/waydroid-sys-XXXXXX)"
  sudo mount -o rw,loop "$IMG" "$TMP_MNT"
  printf '%s\n' "$KL_CONTENT" | sudo tee "$TMP_MNT/$KL_PATH" >/dev/null
  sudo umount "$TMP_MNT" && rmdir "$TMP_MNT"
  if $WAS_ACTIVE; then
    sudo systemctl start waydroid-container.service
    ensure_container_active
  fi
  ok "$KL_PATH → Android system.img"
fi

# ── 5. firewalld ──────────────────────────────────────────────────────────
step "5/7  firewalld (internet for Android)"
sudo systemctl enable --now firewalld

fwadd_iface() {
  if ! sudo firewall-cmd --permanent --zone="$1" --query-interface="$2" &>/dev/null; then
    sudo firewall-cmd --permanent --zone="$1" --add-interface="$2"
    ok "firewall: +interface $2 → zone $1"
  else
    skip "firewall: interface $2 in zone $1"
  fi
}
fwadd_port() {
  if ! sudo firewall-cmd --permanent --zone="$1" --query-port="$2" &>/dev/null; then
    sudo firewall-cmd --permanent --zone="$1" --add-port="$2"
    ok "firewall: +port $2 → zone $1"
  else
    skip "firewall: port $2 in zone $1"
  fi
}
fwadd_masq() {
  if ! sudo firewall-cmd --permanent --zone="$1" --query-masquerade &>/dev/null; then
    sudo firewall-cmd --permanent --zone="$1" --add-masquerade
    ok "firewall: +masquerade → zone $1"
  else
    skip "firewall: masquerade in zone $1"
  fi
}

fwadd_iface trusted waydroid0
fwadd_port  trusted 53/udp
fwadd_port  trusted 67/udp
fwadd_masq  trusted
sudo firewall-cmd --reload
ok "firewall-cmd --reload"

# ── 6. Enable service ─────────────────────────────────────────────────────
step "6/7  systemctl enable waydroid-container"
if systemctl is-enabled --quiet waydroid-container.service 2>/dev/null; then
  skip "waydroid-container.service already enabled"
else
  sudo systemctl enable waydroid-container.service
  ok "waydroid-container.service enabled"
fi

# Gamepad: uevent retrigger (Bazzite pattern).
# udev=true/uevent=true props enable forwarding, but Android may miss the controller —
# the "add" event arrived before forwarding started. Writing "add" to sysfs manually
# makes the kernel resend the udev event → Android registers the device.
# Script and sudoers in /etc/ → overlay → /var → survive SteamOS updates.
write_etc /etc/waydroid-fix-controllers <<'FIXSCRIPT' || true
#!/bin/bash
echo add | tee /sys/devices/virtual/input/input*/event*/uevent >/dev/null 2>&1 || true
FIXSCRIPT
sudo chmod +x /etc/waydroid-fix-controllers

# IMPORTANT: the filename must sort after wheel/wheel-prepare-oobe-test alphabetically —
# otherwise %wheel ALL=(ALL) ALL overrides our NOPASSWD (last rule wins).
# zz-... is guaranteed to be last among all SteamOS sudoers.d files.
sudo rm -f /etc/sudoers.d/waydroid-fix-controllers 2>/dev/null || true
write_etc /etc/sudoers.d/zz-waydroid-fix-controllers <<SUDOERS || true
deck ALL=(ALL) NOPASSWD: /etc/waydroid-fix-controllers
SUDOERS
sudo chmod 440 /etc/sudoers.d/zz-waydroid-fix-controllers
ok "fix-controllers: /etc/waydroid-fix-controllers + sudoers (zz-...)"

# ── 7. libhoudini (ARM translation) ──────────────────────────────────────
step "7/7  libhoudini — ARM translation"

# Check the real file via debugfs, not ro.dalvik.vm.native.bridge in
# waydroid.cfg — `waydroid init` sets that property by default regardless of
# whether libhoudini.so was ever actually copied in.
houdini_installed() {
  local st size
  st="$(debugfs -R "stat /system/lib64/libhoudini.so" "$IMG" 2>/dev/null)"
  size="$(grep -oE 'Size: [0-9]+' <<<"$st" | head -1 | grep -oE '[0-9]+')" || true
  grep -q "Type: regular" <<<"$st" && [[ "${size:-0}" -gt 0 ]]
}

if houdini_installed; then
  skip "libhoudini already installed"
else
  if [[ ! -d "$SCRIPT_DIR/.git" ]]; then
    git clone https://github.com/casualsnek/waydroid_script "$SCRIPT_DIR"
    ok "waydroid_script cloned"
  else
    skip "waydroid_script already cloned"
  fi

  if [[ ! -d "$SCRIPT_DIR/venv" ]]; then
    python3 -m venv "$SCRIPT_DIR/venv"
    "$SCRIPT_DIR/venv/bin/pip" install -q -r "$SCRIPT_DIR/requirements.txt"
    ok "Python venv created"
  else
    skip "Python venv already created"
  fi

  CONTAINER_PY="$SCRIPT_DIR/tools/container.py"
  # Check the exact patched line — upstream's own upgrade() already contains
  # an unrelated ignore=r"...", so a loose substring check always false-
  # positives as "patched". The patch itself isn't optional: `waydroid
  # container stop` always writes to stderr, and their run() raises on any
  # non-empty stderr regardless of exit code.
  PATCHED_STOP='run(["waydroid", "container", "stop"], ignore=r"\[.*\] Stopping container")'
  if grep -qF "$PATCHED_STOP" "$CONTAINER_PY" 2>/dev/null; then
    skip "container.py patch already applied"
  else
    python3 - "$CONTAINER_PY" <<'PYEOF'
import sys
path = sys.argv[1]
content = open(path).read()
old = 'run(["waydroid", "container", "stop"])'
new = 'run(["waydroid", "container", "stop"], ignore=r"\\[.*\\] Stopping container")'
if old not in content:
    print("WARN: pattern not found — upstream may have changed")
    sys.exit(0)
open(path, 'w').write(content.replace(old, new, 1))
PYEOF
    # Silently exits 0 without patching if upstream reformatted `old` — verify
    # the result instead of trusting the exit code.
    grep -qF "$PATCHED_STOP" "$CONTAINER_PY" 2>/dev/null ||
      die "container.py patch didn't take (upstream may have changed stop()) — check $CONTAINER_PY manually"
    ok "container.py patch applied"
  fi

  # Don't pre-start the service: install_app() manages container stop/start
  # itself. Starting it first breaks their internal mount() — verified live,
  # libhoudini.so silently fails to land when the service is already active.
  sudo PATH="$NIX_BIN:$PATH" "$SCRIPT_DIR/venv/bin/python3" "$SCRIPT_DIR/main.py" install libhoudini

  # "installation finished" doesn't mean it actually landed — verify on disk.
  houdini_installed || die "libhoudini reported installed but /system/lib64/libhoudini.so is missing — see install output above"
  ok "libhoudini installed (verified on disk)"
fi

# ── Final check ────────────────────────────────────────────────────────────
# Unconditional restart rather than "start only if inactive" — guarantees the
# LXC container and system.img/vendor.img mounts are fresh with every fix
# above applied, instead of relying on each step's own restore logic.
sudo systemctl restart waydroid-container.service
ensure_container_active
ok "waydroid-container.service restarted — all fixes guaranteed to be applied"

# ── Done ──────────────────────────────────────────────────────────────────
printf '\n\033[32m✓ Setup complete!\033[0m\n\n'
printf '  Launch Android:\n'
printf '    waydroid session start &\n'
printf '    sleep 8 && waydroid show-full-ui\n\n'
printf '  Reminder: BIOS → UMA Frame Buffer Size → 4G (for games)\n\n'
printf '  \033[33mRe-run this script after:\033[0m\n'
printf '    - waydroid upgrade — fully rewrites system.img/vendor.img and wipes the\n'
printf '      overlay, the right-stick .kl fix and libhoudini get lost, need to reapply\n'
printf '    - major SteamOS updates — just in case; configs in /etc/ survive updates\n'
printf '      on their own, but the script is idempotent and it will not hurt to rerun\n\n'
