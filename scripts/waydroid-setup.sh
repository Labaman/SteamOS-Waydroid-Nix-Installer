#!/usr/bin/env bash
# Waydroid installer for SteamOS
# Run: waydroid-setup
set -euo pipefail

NIX_BIN="$HOME/.nix-profile/bin"
WAYDROID_BIN="$NIX_BIN/waydroid"
WAYDROID_DATA="$HOME/.local/share/waydroid"
SCRIPT_DIR="$HOME/waydroid_script"
WAYDROID_CFG="/var/lib/waydroid/waydroid.cfg"
IMG="$WAYDROID_DATA/images/system.img"

# Binder: SteamOS kernels since 6.18 have no binder. Build the in-tree driver from the
# kernel.org sources of the running kernel version (+ shim.c) and load it from
# /etc/waydroid-binder/<uname -r>/.
KREL="$(uname -r)"
KVER="${KREL%%-*}"                                   # 7.2.7-valve1-1-... -> 7.2.7
case "$KVER" in *.0) BINDER_SRC_TAG="v${KVER%.0}" ;; *) BINDER_SRC_TAG="v$KVER" ;; esac
BINDER_ETC_DIR="/etc/waydroid-binder"
BINDER_KO="$BINDER_ETC_DIR/$KREL/binder_linux.ko"
BINDER_STAMP="$BINDER_ETC_DIR/$KREL/source.stamp"
BINDER_SHIM_DIR="$HOME/.local/share/waydroid-setup"  # shim.c + shim.h (from home.nix)
BINDER_HEADERS_CACHE="$HOME/.cache/waydroid-setup"   # kernel headers packages, only needed for the build
BINDER_KEYRING="/usr/share/pacman/keyrings/holo.gpg" # Valve's package signing keys (from the SteamOS image)

ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
skip() { printf '\033[33m→\033[0m %s (already done)\n' "$*"; }
step() { printf '\n\033[1;34m══ %s ══\033[0m\n' "$*"; }
die()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# Writes a file only if content or mode changed (mode is a parameter).
write_file() {
  local dest="$1" mode="${2:-644}"
  local tmp; tmp=$(mktemp)
  cat > "$tmp"
  if sudo test -f "$dest" && sudo cmp -s "$tmp" "$dest" 2>/dev/null \
     && [[ "$(sudo stat -c %a "$dest" 2>/dev/null)" == "$mode" ]]; then
    skip "$dest"; rm -f "$tmp"; return 1
  fi
  sudo install -D -m "$mode" "$tmp" "$dest"
  rm -f "$tmp"
  ok "Written $dest"
}

# casefold on the Waydroid data filesystem breaks overlay mounts; checked on every run.
overlayfs_supported() {
  local dev features
  dev="$(findmnt -n -o SOURCE --target "$WAYDROID_DATA" 2>/dev/null)" || return 1
  features="$(sudo tune2fs -l "$dev" 2>/dev/null)" || return 1
  ! grep -qw casefold <<<"$features"
}

# Waits for waydroid-container.service (Type=dbus) to acquire its bus name.
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

# Files written by earlier versions of this script that are no longer needed.
OBSOLETE_ETC_FILES=(
  /etc/gbinder.d/waydroid.conf   # Waydroid passes the binder protocol to libgbinder itself
)
cleanup_obsolete() {
  local f
  for f in "${OBSOLETE_ETC_FILES[@]}"; do
    if sudo test -e "$f"; then
      sudo rm -f "$f"
      ok "Removed obsolete $f"
    fi
  done
  if [[ -d /etc/gbinder.d ]] && [[ -z "$(ls -A /etc/gbinder.d)" ]]; then
    sudo rmdir /etc/gbinder.d && ok "Removed empty /etc/gbinder.d"
  fi
}

# Is binder built into the kernel itself? Both drivers are bool (never in-tree modules):
# the C one has binderfs only with BINDERFS, the Rust one (Arch's default since 6.18)
# always includes its own binderfs.
binder_builtin() {
  zgrep -qE '^CONFIG_ANDROID_(BINDERFS|BINDER_IPC_RUST)=y' /proc/config.gz 2>/dev/null
}

# A binder_linux module installed on the system by something else (DKMS etc.).
binder_system_module() {
  modinfo -n binder_linux &>/dev/null
}

# Removes what our own module build left behind; called when the build isn't needed.
cleanup_binder_build() {
  local cleaned=false
  if [[ -d "$BINDER_ETC_DIR" ]]; then
    sudo rm -rf "$BINDER_ETC_DIR"
    ok "Removed previously built binder modules: $BINDER_ETC_DIR"; cleaned=true
  fi
  if [[ -d "$BINDER_HEADERS_CACHE" ]]; then
    rm -rf "$BINDER_HEADERS_CACHE"
    ok "Removed kernel headers cache: $BINDER_HEADERS_CACHE"; cleaned=true
  fi
  if $cleaned; then
    printf '\033[33m→\033[0m Build tools in /nix/store are freed by: nix-collect-garbage\n'
  fi
}

# Prints "<package> <version>" of the running kernel.
# -Qoq/-Q print untranslated names; parsing the -Qo sentence breaks in other locales.
# Ask for pkgbase, not the directory: an installed -headers package owns the directory too.
kernel_package() {
  local kpkg kver
  kpkg="$(pacman -Qoq "/usr/lib/modules/$KREL/pkgbase" 2>/dev/null)" || return 1
  kver="$(pacman -Q "$kpkg" 2>/dev/null | awk '{print $2}')" || return 1
  [[ -n "$kpkg" && -n "$kver" ]] && printf '%s %s\n' "$kpkg" "$kver"
}

# Gets headers package $1 version $2 (from the cache or Valve's mirror), verifies it and sets
# HEADERS_FILE. $3 is the caller's work directory.
# The package is always checked by Valve's signature (keys from the SteamOS image); the repo db is
# unsigned, so its sha256 is only an extra check. After a SteamOS update the repo db only lists the
# new kernel, so for a system that hasn't been updated yet the package is taken from the mirror.
fetch_kernel_headers() {
  local hpkg="$1" kver="$2" work="$3" mirror repos repo url="" desc="" file sum="" check
  mirror="$(grep -m1 '^Server' /etc/pacman.d/mirrorlist | sed 's/^Server *= *//')"
  repos="$(grep -oE '^\[[^]]+\]' /etc/pacman.conf | tr -d '[]' | grep -vx options)"

  for repo in $repos; do
    url="${mirror//\$repo/$repo}"; url="${url//\$arch/x86_64}"
    curl -fsSL -o "$work/$repo.db" "$url/$repo.db" || continue
    desc="$(bsdtar -xOf "$work/$repo.db" "$hpkg-$kver/desc" 2>/dev/null)" || true
    [[ -n "$desc" ]] && break
  done
  if [[ -n "$desc" ]]; then
    file="$(grep -A1 '^%FILENAME%$' <<<"$desc" | tail -1)"
    sum="$(grep -A1 '^%SHA256SUM%$' <<<"$desc" | tail -1)"
    curl -fsSL -o "$work/$file.sig" "$url/$file.sig" 2>/dev/null \
      || die "no signature $file.sig in the $repo repo — refusing to use unsigned headers"
    check="Valve's signature and sha256 from the $repo repo database"
  else
    file="$hpkg-$kver-x86_64.pkg.tar.zst"
    for repo in $repos; do
      url="${mirror//\$repo/$repo}"; url="${url//\$arch/x86_64}"
      curl -fsSL -o "$work/$file.sig" "$url/$file.sig" 2>/dev/null && break
      url=""
    done
    [[ -n "$url" ]] || die "headers $hpkg-$kver for kernel $KREL are not in Valve's repos or on the mirror. \
A SteamOS update is probably available — update and run this script again."
    check="Valve's signature"
    printf '\033[33m→\033[0m %s-%s is no longer in the repo database (SteamOS update available?) — using the file from the %s mirror, checked by signature\n' \
      "$hpkg" "$kver" "$repo"
  fi
  gpg --batch --quiet --homedir "$work" --dearmor <"$BINDER_KEYRING" >"$work/holo.gpg" \
    || die "could not read Valve's keys from $BINDER_KEYRING"

  headers_ok() {
    { [[ -z "$sum" ]] || echo "$sum  $1" | sha256sum -c --status; } \
      && gpgv --homedir "$work" --keyring "$work/holo.gpg" "$work/$file.sig" "$1" 2>/dev/null
  }

  # Header cache; wget -c resumes interrupted downloads.
  mkdir -p "$BINDER_HEADERS_CACHE"
  if [[ -f "$BINDER_HEADERS_CACHE/$file" ]] && headers_ok "$BINDER_HEADERS_CACHE/$file"; then
    ok "Headers from cache: $file"
  else
    ok "Downloading $file ($repo)"
    wget -q -c --tries=50 --waitretry=3 --retry-connrefused --read-timeout=20 --timeout=30 \
      -O "$BINDER_HEADERS_CACHE/$file" "$url/$file" || die "failed to download headers $file"
    headers_ok "$BINDER_HEADERS_CACHE/$file" \
      || { rm -f "$BINDER_HEADERS_CACHE/$file"; die "headers $file failed the check: $check"; }
  fi
  HEADERS_FILE="$BINDER_HEADERS_CACHE/$file"
}

# Removes cached headers of previous kernels (~40 MB per kernel update), keeps the current one.
prune_headers_cache() {
  local kpkg kver f
  read -r kpkg kver < <(kernel_package) || return 0
  for f in "$BINDER_HEADERS_CACHE"/*-headers-*.pkg.tar.zst; do
    [[ -e "$f" && "${f##*/}" != "$kpkg-headers-$kver-"* ]] || continue
    rm -f "$f" && ok "Removed headers of an old kernel from the cache: ${f##*/}"
  done
}

# Builds binder_linux.ko for the running kernel into $1: Valve headers, drivers/android of the
# same version from kernel.org, gcc from nixpkgs.
build_binder_module() {
  local out="$1" work kpkg kver file kdir gcc_major
  command -v nix >/dev/null || die "nix not found in PATH — needed to build the binder module"
  [[ -r "$BINDER_SHIM_DIR/shim.c" && -r "$BINDER_SHIM_DIR/shim.h" ]] \
    || die "shim.c/shim.h missing in $BINDER_SHIM_DIR — run: home-manager switch"

  work="$(mktemp -d "${TMPDIR:-/tmp}/waydroid-binder-XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$work'; trap - RETURN" RETURN

  read -r kpkg kver < <(kernel_package) || true
  [[ -n "${kpkg:-}" && -n "${kver:-}" ]] \
    || die "could not determine the kernel package for $KREL — check: pacman -Qo /usr/lib/modules/$KREL/pkgbase"
  fetch_kernel_headers "$kpkg-headers" "$kver" "$work"
  file="${HEADERS_FILE##*/}"
  mkdir "$work/hdr"
  bsdtar -xf "$HEADERS_FILE" -C "$work/hdr"
  kdir="$work/hdr/usr/lib/modules/$KREL/build"
  [[ -f "$kdir/.config" ]] || die "$file has no headers for $KREL"

  # drivers/android of the same kernel: Makefile -> objects -> .c -> local headers.
  local base="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/drivers/android"
  local objs need done_f f inc kobjs
  mkdir "$work/src"
  fetch_src() { curl -fsSL "$base/$1?h=$BINDER_SRC_TAG" -o "$work/src/$1"; }
  ok "Downloading drivers/android ($BINDER_SRC_TAG) from kernel.org"
  fetch_src Makefile || die "failed to download drivers/android/Makefile for $BINDER_SRC_TAG"
  objs="$(grep -E '^obj-\$\(CONFIG_ANDROID_BINDER(FS|_IPC)\)' "$work/src/Makefile" \
          | sed 's/.*+=[[:space:]]*//' | tr ' \t' '\n\n' | grep '\.o$' || true)"
  [[ -n "$objs" ]] || die "could not parse binder objects from Makefile $BINDER_SRC_TAG"
  need="$(sed 's/\.o$/.c/' <<<"$objs")"; done_f=""
  while [[ -n "$need" ]]; do
    f="$(head -1 <<<"$need")"; need="$(tail -n +2 <<<"$need")"
    case " $done_f " in *" $f "*) continue ;; esac
    done_f="$done_f $f"
    fetch_src "$f" || die "failed to download drivers/android/$f ($BINDER_SRC_TAG)"
    for inc in $(grep -oE '#include[[:space:]]*"[^"]+"' "$work/src/$f" | sed -E 's/.*"([^"]+)".*/\1/'); do
      case "$inc" in */*) ;; *) need="$need"$'\n'"$inc" ;; esac
    done
  done

  # Our glue: shim + a generated Kbuild (the driver itself is unmodified).
  cp "$BINDER_SHIM_DIR/shim.c" "$BINDER_SHIM_DIR/shim.h" "$work/src/"
  rm -f "$work/src/Makefile"                        # build with our own Kbuild
  kobjs="$(tr '\n' ' ' <<<"$objs")"
  # Kernel differences handled in shim.c: zap_vma_range (7.x) vs zap_page_range_single
  # (6.18); list_lru_add is not exported on 6.18.
  local shimdefs=""
  grep -qE '\bzap_vma_range\(' "$kdir/include/linux/mm.h" && shimdefs+=" -DBINDER_HAVE_ZAP_VMA_RANGE"
  grep -qw list_lru_add "$kdir/Module.symvers" || shimdefs+=" -DBINDER_SHIM_LIST_LRU_ADD"
  cat > "$work/src/Kbuild" <<KBUILD
ccflags-y += -I\$(src) -include \$(src)/shim.h \\
	-DCONFIG_ANDROID_BINDER_IPC=1 -DCONFIG_ANDROID_BINDERFS=1 -DCONFIG_ANDROID_BINDER_DEVICES='"binder"'
CFLAGS_binder.o += -Dinit_module=binder_orig_init_module -D__inittest=binder_orig_inittest
CFLAGS_binder_alloc.o += -Ddebug_mask=alloc_debug_mask
CFLAGS_shim.o += ${shimdefs}
obj-m := binder_linux.o
binder_linux-y := ${kobjs}shim.o
KBUILD

  gcc_major="$(sed -n 's/^CONFIG_GCC_VERSION=\([0-9]*\)[0-9]\{4\}$/\1/p' "$kdir/.config")"
  [[ -n "$gcc_major" ]] || die "could not read the kernel's gcc version from $kdir/.config"
  ok "Building binder_linux (gcc$gcc_major from nixpkgs)"
  # Built without BTF: not needed for binder, and it would tie loading to the pahole version.
  nix shell "nixpkgs#gcc$gcc_major" nixpkgs#gnumake nixpkgs#binutils nixpkgs#elfutils nixpkgs#pahole \
    -c make -C "$kdir" M="$work/src" CONFIG_DEBUG_INFO_BTF_MODULES= modules >"$work/build.log" 2>&1 \
    || { tail -30 "$work/build.log" >&2; die "binder_linux build failed (if modpost says 'undefined!' — add the symbols to shim.c)"; }

  # vermagic starts with the kernel release — otherwise insmod refuses it.
  [[ "$(modinfo -F vermagic "$work/src/binder_linux.ko" | awk '{print $1}')" == "$KREL" ]] \
    || die "built binder_linux.ko does not match kernel $KREL (vermagic)"
  cp "$work/src/binder_linux.ko" "$out/binder_linux.ko"
}

# ── Uninstall: waydroid-setup --uninstall [--dry-run] ───────────────────────
# Removes everything this script and Waydroid added to the system. Home Manager packages and
# scripts are removed by Home Manager itself. --dry-run only prints what would be done.
UNINSTALL_ETC=(
  /etc/systemd/system/waydroid-container.service
  /etc/dbus-1/system.d/id.waydro.Container.conf
  /etc/waydroid-fix-controllers
  /etc/sudoers.d/zz-waydroid-fix-controllers
  /etc/sudoers.d/waydroid-fix-controllers        # old rule name
  /etc/atomic-update.conf.d/waydroid.conf
  "$BINDER_ETC_DIR"
  "${OBSOLETE_ETC_FILES[@]}"
)
uninstall_waydroid() {
  local dry=false f spec a size data_home title apps=()
  [[ "${1:-}" == --dry-run ]] && dry=true
  act()       { if $dry; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }
  act_quiet() { if $dry; then printf '  [dry-run] %s\n' "$*"; else "$@" &>/dev/null; fi; }
  done_() { $dry || ok "$*"; }

  data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
  shopt -s nullglob
  apps=("$data_home"/applications/waydroid.*.desktop "$data_home"/applications/Waydroid.desktop)
  shopt -u nullglob
  [[ "$WAYDROID_DATA" == "$HOME/.local/share/waydroid" ]] || die "unexpected WAYDROID_DATA: $WAYDROID_DATA"
  size="$(sudo du -sh "$WAYDROID_DATA" 2>/dev/null | cut -f1)" || true

  title="Uninstall Waydroid"; $dry && title+=" (dry run — nothing is changed)"
  step "$title"
  printf '%s\n' "This removes:" \
    "  • the waydroid-container service and files in /etc (D-Bus, sudoers, keep-list, binder module)" \
    "  • firewalld rules in the trusted zone: waydroid0, 53/udp, 67/udp, masquerade" \
    "  • Android with all its data: $WAYDROID_DATA (${size:-?}) and /var/lib/waydroid" \
    "  • Android app shortcuts: ${#apps[@]}" \
    "  • $SCRIPT_DIR, ~/.cache/waydroid-script, $BINDER_HEADERS_CACHE"
  if ! $dry; then
    read -rp "Continue? [y/N] " a
    [[ "$a" == [yY]* ]] || die "Cancelled"
  fi

  [[ -x "$WAYDROID_BIN" ]] && { act_quiet "$WAYDROID_BIN" session stop || true; }
  if systemctl cat waydroid-container.service &>/dev/null; then
    act sudo systemctl disable --now waydroid-container.service || true
    done_ "waydroid-container.service stopped and disabled"
  fi

  for f in "${UNINSTALL_ETC[@]}"; do
    if sudo test -e "$f"; then act sudo rm -rf "$f"; done_ "Removed $f"; fi
  done
  if [[ -d /etc/gbinder.d ]] && [[ -z "$(ls -A /etc/gbinder.d)" ]]; then act sudo rmdir /etc/gbinder.d; fi
  act sudo systemctl daemon-reload
  act sudo systemctl reload dbus.service

  # Only our rules; firewalld itself stays enabled.
  if command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld; then
    for spec in interface=waydroid0 port=53/udp port=67/udp masquerade; do
      if sudo firewall-cmd --permanent --zone=trusted "--query-$spec" &>/dev/null; then
        act_quiet sudo firewall-cmd --permanent --zone=trusted "--remove-$spec"
        done_ "firewall: -$spec (zone trusted)"
      fi
    done
    act_quiet sudo firewall-cmd --reload
  fi

  # Never rm -rf into active mounts of the container.
  if findmnt -rn -o TARGET | grep -qE "^($WAYDROID_DATA|/var/lib/waydroid)(/|$)"; then
    $dry && printf '  [dry-run] Waydroid data is mounted now — the container is stopped first on a real run\n' \
      || die "something is mounted under $WAYDROID_DATA or /var/lib/waydroid — reboot and run this again"
  fi
  if [[ -L /var/lib/waydroid ]]; then act sudo rm -f /var/lib/waydroid; done_ "Removed the /var/lib/waydroid symlink"
  elif [[ -e /var/lib/waydroid ]]; then act sudo rm -rf /var/lib/waydroid; done_ "Removed /var/lib/waydroid"; fi
  if [[ -e "$WAYDROID_DATA" ]]; then act sudo rm -rf "$WAYDROID_DATA"; done_ "Removed $WAYDROID_DATA"; fi

  if (( ${#apps[@]} )); then
    act rm -f "${apps[@]}"; done_ "Removed Android app shortcuts: ${#apps[@]}"
    if [[ -x /usr/bin/kbuildsycoca6 ]]; then
      act_quiet env -u LD_LIBRARY_PATH PATH="/usr/bin:$PATH" /usr/bin/kbuildsycoca6 --noincremental || true
    fi
  fi

  [[ -e "$SCRIPT_DIR" ]] && { act rm -rf "$SCRIPT_DIR"; done_ "Removed $SCRIPT_DIR"; }
  [[ -e "$HOME/.cache/waydroid-script" ]] && { act sudo rm -rf "$HOME/.cache/waydroid-script"; done_ "Removed ~/.cache/waydroid-script"; }
  [[ -e "$BINDER_HEADERS_CACHE" ]] && { act rm -rf "$BINDER_HEADERS_CACHE"; done_ "Removed $BINDER_HEADERS_CACHE"; }

  $dry && { printf '\nDry run: nothing was changed.\n'; return 0; }
  printf '\n\033[32m✓\033[0m Waydroid has been removed.\n'
  printf '  • The binder module is unloaded on the next reboot.\n'
  printf '  • Home Manager removes the Waydroid packages and scripts: delete the Waydroid section from\n'
  printf '    home.nix and run home-manager switch (or remove Home Manager and Nix — see the nix-hm-conf-steamos README).\n'
  printf '  • Remove the Waydroid shortcut in Steam yourself.\n'
}

case "${1:-}" in
  "") ;;
  --uninstall) uninstall_waydroid "${2:-}"; exit 0 ;;
  *) die "unknown option: $1 (only --uninstall [--dry-run] is supported)" ;;
esac

# ── 1. Check dependencies ─────────────────────────────────────────────────
step "1/8  Check dependencies"
[[ -x "$WAYDROID_BIN" ]]       || die "waydroid not found — run: home-manager switch"
[[ -x "$NIX_BIN/lxc-start" ]] || die "lxc not found — run: home-manager switch"
ok "waydroid and lxc found"

# ── 2. Binder ─────────────────────────────────────────────────────────────
# Mode: builtin (nothing to do), system (modprobe), ours (build; insmod from
# /etc/waydroid-binder/%v/). After a kernel update re-run this script.
step "2/8  Binder (kernel $KREL)"
if binder_builtin; then
  BINDER_MODE=builtin
  skip "binder is built into the kernel — no module needed"
  cleanup_binder_build
elif binder_system_module; then
  BINDER_MODE=system
  skip "binder_linux module already on the system ($(modinfo -n binder_linux)) — no build needed"
  cleanup_binder_build
else
  BINDER_MODE=ours
  # Rebuild only if there is no module for this kernel from the same source.
  stamp="tag=$BINDER_SRC_TAG shim=$(sha256sum "$BINDER_SHIM_DIR/shim.c" 2>/dev/null | cut -d' ' -f1)"
  if [[ -f "$BINDER_KO" ]] && [[ "$(cat "$BINDER_STAMP" 2>/dev/null)" == "$stamp" ]]; then
    skip "$BINDER_KO built from the same source"
  else
    build_dir="$(mktemp -d "${TMPDIR:-/tmp}/waydroid-binder-out-XXXXXX")"
    build_binder_module "$build_dir"
    write_file "$BINDER_KO" 644 < "$build_dir/binder_linux.ko" || true
    printf '%s\n' "$stamp" | write_file "$BINDER_STAMP" 644 || true
    rm -rf "$build_dir"
    # A loaded module can't be swapped live (no rmmod while the container has
    # binderfs mounted) — the new build is picked up on the next boot.
    if grep -qw binder /proc/filesystems; then
      printf '\033[33m→\033[0m binder_linux already loaded — the new build takes effect after reboot\n'
    fi
  fi
  # Modules for previous kernels are no longer needed (one kernel per slot).
  sudo find "$BINDER_ETC_DIR" -mindepth 1 -maxdepth 1 -type d ! -name "$KREL" \
    -exec rm -rf {} + -exec printf '\033[32m✓\033[0m Removed module for old kernel: %s\n' {} \;
  prune_headers_cache
fi

if grep -qw binder /proc/filesystems; then
  skip "binderfs available in the kernel"
else
  case "$BINDER_MODE" in
    system) sudo modprobe binder_linux ;;
    ours)   sudo insmod "$BINDER_KO" ;;
  esac
  grep -qw binder /proc/filesystems || die "binderfs unavailable after loading the module — check: sudo dmesg | tail"
  ok "binder_linux module loaded"
fi

case "$BINDER_MODE" in
  builtin) BINDER_EXEC_START_PRE="" ;;
  system)  BINDER_EXEC_START_PRE="ExecStartPre=/usr/bin/modprobe binder_linux" ;;
  ours)    BINDER_EXEC_START_PRE="ExecStartPre=/bin/sh -c 'grep -qw binder /proc/filesystems || exec /usr/bin/insmod $BINDER_ETC_DIR/%v/binder_linux.ko'" ;;
esac

# ── 3. /etc files ─────────────────────────────────────────────────────────
step "3/8  /etc configs (systemd, D-Bus)"

# RAUC wipes /etc outside its keep-list; list the Waydroid files so they survive updates.
# The built modules are listed only while we build them.
{
  cat <<'KEEPLIST'
# Waydroid files RAUC would otherwise wipe on a SteamOS atomic update.
# The systemd unit + enable symlink aren't needed here — the base keep-list covers them.
/etc/dbus-1/system.d/id.waydro.Container.conf
/etc/waydroid-fix-controllers
/etc/sudoers.d/zz-waydroid-fix-controllers
/etc/firewalld/zones/trusted.xml
KEEPLIST
  if [[ "$BINDER_MODE" == ours ]]; then printf '%s/**\n' "$BINDER_ETC_DIR"; fi
} | write_file /etc/atomic-update.conf.d/waydroid.conf || true

RELOAD_SYSTEMD=false
RELOAD_DBUS=false

if write_file /etc/systemd/system/waydroid-container.service <<UNIT
[Unit]
Description=Waydroid Container
After=network.target dbus.service

[Service]
Type=dbus
BusName=id.waydro.Container
Environment=PATH=$NIX_BIN:/usr/bin:/bin
$BINDER_EXEC_START_PRE
ExecStart=$WAYDROID_BIN container start
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
then RELOAD_SYSTEMD=true; fi

if write_file /etc/dbus-1/system.d/id.waydro.Container.conf <<DBUS
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

cleanup_obsolete

$RELOAD_SYSTEMD && { sudo systemctl daemon-reload; ok "daemon-reload"; }
$RELOAD_DBUS    && { sudo systemctl reload dbus.service; ok "D-Bus reloaded"; }

# Restart the container once if dbus/systemd config changed while it was running
# (it reads them only at startup).
if { $RELOAD_SYSTEMD || $RELOAD_DBUS; } && systemctl is-active --quiet waydroid-container.service; then
  sudo systemctl restart waydroid-container.service
  ensure_container_active
  ok "waydroid-container.service restarted (picking up new config)"
fi

# ── 4. Android data: directory + symlink ──────────────────────────────────
step "4/8  Data directory and /var/lib/waydroid symlink"
mkdir -p "$WAYDROID_DATA"

if [[ "$(readlink /var/lib/waydroid 2>/dev/null)" == "$WAYDROID_DATA" ]]; then
  skip "/var/lib/waydroid → $WAYDROID_DATA"
else
  sudo rm -rf /var/lib/waydroid
  sudo ln -sf "$WAYDROID_DATA" /var/lib/waydroid
  ok "Symlink /var/lib/waydroid → $WAYDROID_DATA"
fi

# ── 5. waydroid init ──────────────────────────────────────────────────────
# Init needs both images; if the vendor download was interrupted, re-run with -f.
step "5/8  waydroid init (Android 13 + GAPPS, ~3 GB)"
if [[ -f "$WAYDROID_DATA/images/system.img" && -f "$WAYDROID_DATA/images/vendor.img" ]]; then
  skip "Android images already downloaded"
else
  init_args=(init -s GAPPS)
  if [[ -e "$WAYDROID_DATA/images/system.img" || -e "$WAYDROID_DATA/images/vendor.img" || -e "$WAYDROID_CFG" ]]; then
    init_args+=(-f)
    printf '\033[33m→\033[0m Previous init did not finish (an image is missing) — rerunning with -f\n'
  fi
  sudo PATH="$NIX_BIN:$PATH" "$WAYDROID_BIN" "${init_args[@]}" \
    || die "waydroid init failed (interrupted download?) — just run waydroid-setup again"
  [[ -f "$WAYDROID_DATA/images/system.img" && -f "$WAYDROID_DATA/images/vendor.img" ]] \
    || die "system.img or vendor.img missing after waydroid init"
  ok "waydroid init complete"
fi

if [[ "$(stat -c %U "$WAYDROID_DATA")" != "$(whoami)" ]]; then
  sudo chown "$(whoami):$(whoami)" "$WAYDROID_DATA"
  ok "chown $(whoami) $WAYDROID_DATA"
else
  skip "$WAYDROID_DATA owner already correct"
fi

# Binder device names in waydroid.cfg. `waydroid init` stores the devices it found; our
# module also creates "binder" in binderfs, so an install set up with it has binder = binder.
# A kernel with built-in binder (e.g. the Rust binder in SteamOS 3.9.5) doesn't create that
# device, and Android's servicemanager aborts. Waydroid creates the anbox-* devices on every
# session start, so use those; `waydroid upgrade --offline` regenerates the container config
# from waydroid.cfg without touching the images.
BINDER_NODES=(anbox-binder anbox-vndbinder anbox-hwbinder)
LXC_NODES="/var/lib/waydroid/lxc/waydroid/config_nodes"
binder_keys=(binder vndbinder hwbinder)
binder_cfg_ok=true
for i in 0 1 2; do
  key="${binder_keys[i]}" want="${BINDER_NODES[i]}"
  if ! grep -qxF "$key = $want" "$WAYDROID_CFG" 2>/dev/null \
     || ! grep -qF "lxc.mount.entry = /dev/$want dev/$key " "$LXC_NODES" 2>/dev/null; then
    binder_cfg_ok=false
  fi
done
if $binder_cfg_ok; then
  skip "binder devices in waydroid.cfg: ${BINDER_NODES[*]}"
else
  for i in 0 1 2; do
    key="${binder_keys[i]}" want="${BINDER_NODES[i]}"
    if grep -q "^$key = " "$WAYDROID_CFG"; then
      sudo sed -i "s|^$key = .*|$key = $want|" "$WAYDROID_CFG"
    else
      sudo sed -i "/^\[waydroid\]/a $key = $want" "$WAYDROID_CFG"
    fi
  done
  sudo PATH="$NIX_BIN:$PATH" "$WAYDROID_BIN" upgrade --offline \
    || die "waydroid upgrade --offline failed — the container config was not regenerated"
  ok "binder devices in waydroid.cfg: ${BINDER_NODES[*]}, container config regenerated"
fi

# Gamepad: props that forward udev/uevent to the container (source:
# ryanrudolfoba/extras/waydroid_base.prop). Also written to waydroid.cfg [properties],
# which `waydroid upgrade` uses to rebuild base.prop.
for prop in persist.waydroid.udev=true persist.waydroid.uevent=true; do
  key="${prop%%=*}"

  if grep -qxF "$prop" "$WAYDROID_DATA/waydroid_base.prop" 2>/dev/null; then
    skip "prop $prop in waydroid_base.prop"
  else
    echo "$prop" | sudo tee -a "$WAYDROID_DATA/waydroid_base.prop" >/dev/null
    ok "prop $prop → waydroid_base.prop"
  fi

  if sudo grep -qxE "$key[[:space:]]*=[[:space:]]*true" "$WAYDROID_CFG" 2>/dev/null; then
    skip "prop $key in waydroid.cfg [properties]"
  else
    sudo sed -i "/^\[properties\]/a $key = true" "$WAYDROID_CFG"
    ok "prop $key → waydroid.cfg [properties] (survives waydroid upgrade)"
  fi
done

# Sync mount_overlays to what this filesystem can actually do, before the
# kl-fix and libhoudini (step 7) — both branch on it below.
if overlayfs_supported; then
  if grep -q '^mount_overlays = False$' "$WAYDROID_CFG" 2>/dev/null; then
    sudo sed -i 's/^mount_overlays = False$/mount_overlays = True/' "$WAYDROID_CFG"
    ok "overlayfs supported — mount_overlays enabled"
  else
    skip "overlayfs supported, mount_overlays already enabled"
  fi
else
  if grep -q '^mount_overlays = True$' "$WAYDROID_CFG" 2>/dev/null; then
    sudo sed -i 's/^mount_overlays = True$/mount_overlays = False/' "$WAYDROID_CFG"
    ok "overlayfs not supported — mount_overlays disabled"
  else
    skip "overlayfs not supported, mount_overlays already disabled"
  fi
fi

# Right stick: map the Steam virtual gamepad (28de:11ff) like an Xbox 360 pad
# (the default Generic.kl uses the wrong axes).
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

if grep -q '^mount_overlays = True$' "$WAYDROID_CFG" 2>/dev/null; then
  # Overlay supported — Bazzite-style: plain file in overlay/ (extra lowerdir,
  # not upperdir) — no resize2fs/loop-mount/debugfs, survives `waydroid upgrade`.
  printf '%s\n' "$KL_CONTENT" | write_file "$WAYDROID_DATA/overlay/$KL_PATH" 644
else
  # Overlay is unsupported: write the kl into system.img. debugfs checks for it
  # (existence and size) without mounting.
  KL_STAT="$(debugfs -R "stat /$KL_PATH" "$IMG" 2>/dev/null)"
  # head -1: debugfs prints Size twice; || true: the file may not exist yet.
  KL_SIZE="$(grep -oE 'Size: [0-9]+' <<<"$KL_STAT" | head -1 | grep -oE '[0-9]+')" || true
  if grep -q "Type: regular" <<<"$KL_STAT" && [[ "${KL_SIZE:-0}" -gt 0 ]]; then
    skip "$KL_PATH"
  else
    WAS_ACTIVE=false
    if systemctl is-active --quiet waydroid-container.service 2>/dev/null; then
      WAS_ACTIVE=true
      sudo systemctl stop waydroid-container.service && sleep 2
    fi

    # Grow system.img beforehand if it has no free blocks.
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
fi

# ── 6. firewalld ──────────────────────────────────────────────────────────
step "6/8  firewalld (internet for Android)"
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

# ── 7. Enable service ─────────────────────────────────────────────────────
step "7/8  systemctl enable waydroid-container"
if systemctl is-enabled --quiet waydroid-container.service 2>/dev/null; then
  skip "waydroid-container.service already enabled"
else
  sudo systemctl enable waydroid-container.service
  ok "waydroid-container.service enabled"
fi

# Gamepads: Android only picks up devices plugged in after the session starts, so resend
# "add" uevents for connected ones. No argument: Steam Input virtual pads (Game Mode);
# "physical": USB/Bluetooth gamepads (Desktop Mode).
FIXCTL_CHANGED=false
if write_file /etc/waydroid-fix-controllers 755 <<'FIXSCRIPT'
#!/bin/bash
if [ "$1" = physical ]; then
  for js in /sys/class/input/js*; do
    d=$(readlink -f "$js/device")
    case "$d" in /sys/devices/virtual/input/*) continue ;; esac
    for e in "$d"/event*/uevent; do echo add > "$e"; done
  done 2>/dev/null
else
  echo add | tee /sys/devices/virtual/input/input*/event*/uevent >/dev/null 2>&1
fi
exit 0
FIXSCRIPT
then FIXCTL_CHANGED=true; fi

# Must sort after wheel* in sudoers.d (last rule wins).
sudo rm -f /etc/sudoers.d/waydroid-fix-controllers 2>/dev/null || true
if write_file /etc/sudoers.d/zz-waydroid-fix-controllers 440 <<SUDOERS
deck ALL=(ALL) NOPASSWD: /etc/waydroid-fix-controllers
SUDOERS
then FIXCTL_CHANGED=true; fi

if $FIXCTL_CHANGED; then
  ok "fix-controllers: /etc/waydroid-fix-controllers + sudoers (zz-...)"
else
  skip "fix-controllers: /etc/waydroid-fix-controllers + sudoers (zz-...)"
fi

# ── 8. libhoudini (ARM translation) ──────────────────────────────────────
step "8/8  libhoudini — ARM translation"

# Check the real file: ro.dalvik.vm.native.bridge is set even if libhoudini.so is missing.
houdini_installed() {
  if grep -q '^mount_overlays = True$' "$WAYDROID_CFG" 2>/dev/null; then
    [[ -s "$WAYDROID_DATA/overlay/system/lib64/libhoudini.so" ]]
    return
  fi
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
  # Check the exact patched line (upstream upgrade() has a similar ignore=r"...");
  # the patch is required: `container stop` writes to stderr and run() raises on it.
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

  # Don't pre-start the service: install_app() manages container stop/start itself.
  sudo PATH="$NIX_BIN:$PATH" "$SCRIPT_DIR/venv/bin/python3" "$SCRIPT_DIR/main.py" install libhoudini

  # "installation finished" doesn't mean it actually landed — verify on disk.
  houdini_installed || die "libhoudini reported installed but /system/lib64/libhoudini.so is missing — see install output above"
  ok "libhoudini installed (verified on disk)"
fi

# ── Final check ────────────────────────────────────────────────────────────
# Always restart so the container and image mounts are fresh.
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
printf '    - a SteamOS update — /etc configs are now under the RAUC keep-list\n'
printf '      (/etc/atomic-update.conf.d/waydroid.conf) and survive; if something\n'
printf '      is off, the script is idempotent and will restore it\n\n'
