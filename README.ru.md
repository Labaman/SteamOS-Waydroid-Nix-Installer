# SteamOS-Waydroid-Nix-Installer

[English](README.md) | **Русский**

Устанавливает [Waydroid](https://waydroid.io/) (Android 13 + GAPPS) на Steam Deck через Nix + Home Manager.

Делает всё то же, что [nix-hm-conf-steamdeck](https://github.com/Labaman/nix-hm-conf-steamdeck) — базовые фиксы SteamOS, nixGL, строка приглашения оболочки, Wayland — плюс устанавливает Android в LXC-контейнере с лаунчером для Game Mode и поддержкой геймпада.

Пакеты и настройки не слетают при обновлениях SteamOS.

## Возможности

| Фикс / Фича | Описание |
|-------------|----------|
| Базовые фиксы SteamOS | Подробнее: [nix-hm-conf-steamdeck](https://github.com/Labaman/nix-hm-conf-steamdeck) |
| Waydroid | Android 13 + GAPPS в LXC-контейнере |
| Лаунчер для Game Mode | `waydroid-gamemode` — добавить в Steam как стороннюю игру |
| Поддержка геймпада | Правый стик корректно маппируется для Android-игр |
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
home-manager switch --flake ~/.config/home-manager#deck
```

Затем запустить скрипт установки Waydroid один раз (~3 ГБ для образа Android):

```bash
waydroid-setup
```

Безопасно перезапускать после обновления SteamOS — уже выполненные шаги пропускаются автоматически.

Свои пакеты и программы добавляй внутри `home.nix` ниже соответствующего комментария.

## Waydroid в Game Mode

После завершения `waydroid-setup` добавить Waydroid в Steam:

**Desktop Mode** → Игры → Добавить игру не из Steam → Обзор → `~/.local/bin/waydroid-gamemode` → переименовать в «Waydroid»

## Оболочка (опционально)

Раскомментируй один блок оболочки в `home.nix` (`bash`, `zsh` или `fish`), чтобы включить строку приглашения Starship и гарантировать попадание переменных сессии в графические приложения.
Подробное сравнение оболочек и инструкции по смене логин-шелла — в [nix-hm-conf-steamdeck](https://github.com/Labaman/nix-hm-conf-steamdeck).

## Благодарности

- [ryanrudolfoba/SteamOS-Waydroid-Installer](https://github.com/ryanrudolfoba/SteamOS-Waydroid-Installer) — подход с cage-лаунчером для Game Mode и udev/uevent пропсы из `waydroid_base.prop`
- [Bazzite](https://github.com/ublue-os/bazzite) — паттерн uevent-ретриггера для поддержки геймпада
- [casualsnek/waydroid_script](https://github.com/casualsnek/waydroid_script) — установщик libhoudini (ARM-трансляция)
