#!/usr/bin/env bash
# Waydroid Game Mode launcher для Steam Deck
set -euo pipefail

# В Game Mode нет видимого stderr → весь вывод в лог для диагностики.
LOG="$HOME/.local/share/waydroid/gamemode.log"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
printf '\n===== waydroid-gamemode %s =====\n' "$(date)"

# Steam Game Mode инжектит LD_PRELOAD=gameoverlayrenderer.so (зависит от libGL.so.1) и
# steam-runtime LD_LIBRARY_PATH — оба ломают Nix-бинари (cage, waydroid: «libGL.so.1 not
# found», не стартует даже bash). Чистим. cage обёрнут nixGL → сам выставит LD_LIBRARY_PATH
# для GPU. (Проверено репродукцией: LD_PRELOAD=оверлей → Nix-bash падает на libGL.)
unset LD_PRELOAD LD_LIBRARY_PATH

NIX_BIN="$HOME/.nix-profile/bin"
# Steam в Game Mode запускает скрипт со СВОИМ PATH (без ~/.nix-profile/bin) → внутри
# `cage -- bash` голые waydroid/wlr-randr не находятся («command not found»). Добавляем
# NIX_BIN в PATH и экспортим → вложенный bash в cage наследует и видит Nix-бинари.
export PATH="$NIX_BIN:$PATH"
WAYDROID="$NIX_BIN/waydroid"
CAGE="$NIX_BIN/cage"
RES="${WAYDROID_RES:-1280x800}"   # родное разрешение Деки; переопределить через env

[[ -x "$WAYDROID" ]] || { echo "FATAL: waydroid нет — home-manager switch"; exit 1; }
[[ -x "$CAGE" ]]     || { echo "FATAL: cage нет — home-manager switch"; exit 1; }

# Контейнер стартует systemd при загрузке (сервис enable). В Game Mode НЕТ способа ввести
# пароль sudo/polkit → НЕ пытаемся стартовать через sudo (зависло бы на запросе пароля —
# одна из причин вечного логотипа). Требуем уже активный сервис.
if ! systemctl is-active --quiet waydroid-container.service; then
  echo "FATAL: waydroid-container.service не активен (должен автозапускаться при загрузке)"
  exit 1
fi

# Очистка при любом выходе (нормальный, SIGTERM от Steam, Ctrl+C)
cleanup() { "$WAYDROID" session stop &>/dev/null || true; }
trap cleanup EXIT

# cage = вложенный Wayland-композитор. gamescope фуллскринит ОКНО cage, а Android рендерит
# внутрь cage. Прямой show-full-ui окна в gamescope НЕ создаёт → gamescope ждёт окно вечно
# → логотип Steam навсегда. cage используют и ryanrudolfoba, и Bazzite — это рабочий путь.
# Внутри cage: задаём разрешение выхода (wlr-randr, авто-детект имени) и стартуем UI.
# cage в foreground: Steam держит «игру» запущенной пока жив скрипт; выход из Android →
# cage завершается → trap чистит сессию.
"$CAGE" -- bash -uc '
  out=$(wlr-randr 2>/dev/null | awk "NR==1{print \$1; exit}")
  [ -n "$out" ] && wlr-randr --output "$out" --custom-mode '"$RES"' 2>/dev/null || true

  waydroid show-full-ui &
  wpid=$!

  # surfaceflinger (внутри Android) поднимается ~15-20с; затем макс. громкость (фикс «нет звука»).
  for _ in $(seq 1 30); do pgrep -x surfaceflinger >/dev/null && break; sleep 1; done
  sleep 5
  waydroid shell -- cmd media_session volume --stream 3 --set 15 2>/dev/null || true
  # Геймпад: uevent-ретриггер — пишем "add" в /sys/.../input*/event*/uevent →
  # ядро шлёт udev-событие → Android видит контроллер (Bazzite pattern).
  env -u LD_LIBRARY_PATH /usr/bin/sudo /etc/waydroid-fix-controllers 2>/dev/null || true

  wait "$wpid"
'
