# SteamOS Waydroid Nix Installer

[English](README.md) | **Русский**

Устанавливает [Waydroid](https://waydro.id) (Android 13 + GAPPS) на SteamOS через Nix + Home Manager.

Делает всё то же, что [nix-hm-conf-steamos](https://github.com/Labaman/nix-hm-conf-steamos) — базовые фиксы SteamOS, GPU-драйверы для Nix-GUI-приложений, строка приглашения оболочки, нативный Wayland для Nix-GUI-приложений (Electron/Chromium + Qt) — плюс устанавливает Android в LXC-контейнере с лаунчером для Game Mode и поддержкой геймпада.

Пакеты и настройки не слетают при обновлениях SteamOS.

## Возможности

| Фикс / Фича | Описание |
|-------------|----------|
| Базовые фиксы SteamOS | Подробнее: [nix-hm-conf-steamos](https://github.com/Labaman/nix-hm-conf-steamos) |
| Waydroid | Android 13 + GAPPS в LXC-контейнере |
| Лаунчер для Game Mode | `waydroid-gamemode` — добавить в Steam как стороннюю игру |
| Поддержка геймпада | Правый стик корректно маппируется для Android-игр |
| Модуль binder | Ядра SteamOS начиная с 6.18 собраны без binder — `waydroid-setup` собирает штатный in-tree binder под текущее ядро (исходники с kernel.org + небольшая прослойка через kallsyms, без патчей драйвера); пропускается, если binder встроен в ядро |
| ARM-трансляция | libhoudini через [casualsnek/waydroid_script](https://github.com/casualsnek/waydroid_script) |

## Требования

- SteamOS 3.5 и выше
- ~3 ГБ свободного места на встроенном накопителе под образ Android

## Использование

Установить Nix, если ещё не установлен ([NixOS/nix-installer](https://github.com/NixOS/nix-installer), автоматически определяет SteamOS):

```bash
curl -sSfL https://artifacts.nixos.org/nix-installer | sh -s -- install --enable-flakes
```

Клонировать и применить:

```bash
git clone https://github.com/Labaman/SteamOS-Waydroid-Nix-Installer ~/.config/home-manager
nix run home-manager/master -- switch
```

Первый запуск берёт Home Manager прямо с GitHub через `nix run` — отдельно ставить его не нужно. После этого команда `home-manager` уже есть в профиле, и дальше достаточно `home-manager switch`.

Настроить GPU-драйверы для Nix GUI-приложений (спросит пароль sudo; перезапускать, когда `switch` предупреждает, что драйверы требуют обновления):

```bash
nix-gpu-setup
```

Затем запустить скрипт установки Waydroid один раз (~3 ГБ для образа Android):

```bash
waydroid-setup
```

Безопасно перезапускать после обновления SteamOS — уже выполненные шаги пропускаются автоматически. Перезапускай его после каждого обновления SteamOS, которое меняет ядро: он пересоберёт модуль binder под новое ядро, иначе `waydroid-container.service` не запустится.

Свои пакеты и программы добавляй внутри `home.nix` ниже соответствующего комментария.

## Waydroid в Game Mode

После завершения `waydroid-setup` добавить Waydroid в Steam:

**Desktop Mode** → Игры → Добавить игру не из Steam → Обзор → `~/.local/bin/waydroid-gamemode` → переименовать в «Waydroid»

## Оболочка (опционально)

Раскомментируй один блок оболочки в `home.nix` (`bash`, `zsh` или `fish`), чтобы включить строку приглашения Starship и гарантировать попадание переменных сессии в графические приложения.
Подробное сравнение оболочек и инструкции по смене логин-шелла — в [nix-hm-conf-steamos](https://github.com/Labaman/nix-hm-conf-steamos).

## Благодарности

- [ryanrudolfoba/SteamOS-Waydroid-Installer](https://github.com/ryanrudolfoba/SteamOS-Waydroid-Installer) — подход с cage-лаунчером для Game Mode и udev/uevent пропсы из `waydroid_base.prop`
- [Bazzite](https://github.com/ublue-os/bazzite) — паттерн uevent-ретриггера для поддержки геймпада
- [casualsnek/waydroid_script](https://github.com/casualsnek/waydroid_script) — установщик libhoudini (ARM-трансляция)
- Linux kernel `drivers/android` — GPL-2.0 — штатный in-tree binder; исходники берутся при сборке с kernel.org под версию текущего ядра
- The Android Open Source Project — раскладка правого стика (Apache-2.0)

## Лицензия

Под **GNU General Public License v3.0 или новее** (GPL-3.0-or-later) — см. [LICENSE](LICENSE).

Атрибуции сторонних материалов — в [NOTICE](NOTICE). Рантайм-зависимости (Waydroid, waydroid_script, ARM-трансляторы) скачиваются или вызываются при установке и сохраняют свои лицензии — в репозитории они не бандлятся.
