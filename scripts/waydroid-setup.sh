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
write_etc() {
  local dest="$1"
  local tmp; tmp=$(mktemp)
  cat > "$tmp"
  if sudo test -f "$dest" && sudo cmp -s "$tmp" "$dest" 2>/dev/null; then
    skip "$dest"; rm -f "$tmp"; return 1
  fi
  sudo mkdir -p "$(dirname "$dest")"
  sudo cp "$tmp" "$dest"
  rm -f "$tmp"
  ok "Written $dest"
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

write_etc /etc/gbinder.d/waydroid.conf <<GBINDER || true
[Protocol]
/dev/anbox-binder = aidl2
/dev/anbox-vndbinder = aidl2
/dev/anbox-hwbinder = hidl

[ServiceManager]
/dev/anbox-binder = aidl2
/dev/anbox-vndbinder = aidl2
/dev/anbox-hwbinder = hidl
GBINDER

$RELOAD_SYSTEMD && { sudo systemctl daemon-reload; ok "daemon-reload"; }
$RELOAD_DBUS    && { sudo systemctl reload dbus.service; ok "D-Bus reloaded"; }

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
# write kl directly into system.img. Already-done check via debugfs.
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
# Already-done check: debugfs reads the ext4 image directly without mounting and without
# stopping the container — system.img is mounted inside the lxc namespace and is not
# accessible via the host rootfs. debugfs works without sudo (system.img is world-readable).
IMG="$WAYDROID_DATA/images/system.img"
if debugfs -R "stat /$KL_PATH" "$IMG" 2>/dev/null | grep -q "Type: regular"; then
  skip "$KL_PATH"
else
  WAS_ACTIVE=false
  if systemctl is-active --quiet waydroid-container.service 2>/dev/null; then
    WAS_ACTIVE=true
    sudo systemctl stop waydroid-container.service && sleep 2
  fi
  TMP_MNT="$(mktemp -d /tmp/waydroid-sys-XXXXXX)"
  sudo mount -o rw,loop "$IMG" "$TMP_MNT"
  printf '%s\n' "$KL_CONTENT" | sudo tee "$TMP_MNT/$KL_PATH" >/dev/null
  sudo umount "$TMP_MNT" && rmdir "$TMP_MNT"
  $WAS_ACTIVE && sudo systemctl start waydroid-container.service
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

if grep -q 'ro.dalvik.vm.native.bridge' "$WAYDROID_DATA/waydroid.cfg" 2>/dev/null; then
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
  if grep -qF 'ignore=r"' "$CONTAINER_PY" 2>/dev/null; then
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
    ok "container.py patch applied"
  fi

  sudo systemctl start waydroid-container.service
  sleep 3
  sudo PATH="$NIX_BIN:$PATH" "$SCRIPT_DIR/venv/bin/python3" "$SCRIPT_DIR/main.py" install libhoudini
  ok "libhoudini installed"
fi

# ── Done ──────────────────────────────────────────────────────────────────
printf '\n\033[32m✓ Setup complete!\033[0m\n\n'
printf '  Launch Android:\n'
printf '    waydroid session start &\n'
printf '    sleep 8 && waydroid show-full-ui\n\n'
printf '  Reminder: BIOS → UMA Frame Buffer Size → 4G (for games)\n\n'
