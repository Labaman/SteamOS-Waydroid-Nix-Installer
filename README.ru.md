# SteamOS Waydroid Nix Installer

[English](README.md) | **Русский**

> [!WARNING]
> Начиная с версии SteamOS 3.8.28 (ядро linux-neptune-618) поставляется без драйвера
> Android binder (`CONFIG_ANDROID_BINDER_IPC` отключён), а Waydroid без него не
> работает. Этот установщик собирает binder под текущее ядро из штатных исходников
> ядра (mainline) как загружаемый модуль, чтобы Waydroid работал уже сейчас — но
> правильное решение это если Valve вернут binder в ядро SteamOS.
>
> 👉 Поддержите / подпишитесь на issue:
> [ValveSoftware/SteamOS#2848](https://github.com/ValveSoftware/SteamOS/issues/2848).

Устанавливает [Waydroid](https://waydro.id) (Android 13 + GAPPS) на SteamOS через Nix + Home Manager.

Делает всё то же, что [nix-hm-conf-steamos](https://github.com/Labaman/nix-hm-conf-steamos) — базовые фиксы SteamOS, GPU-драйверы для Nix-GUI-приложений, строка приглашения оболочки, нативный Wayland для Nix-GUI-приложений (Electron/Chromium + Qt) — плюс устанавливает Android в LXC-контейнере с лаунчером для Game Mode и поддержкой геймпада.

Пакеты и настройки не слетают при обновлениях SteamOS.

## Возможности

| Фикс / Фича | Описание |
|-------------|----------|
| Базовые фиксы SteamOS | Подробнее: [nix-hm-conf-steamos](https://github.com/Labaman/nix-hm-conf-steamos) |
| Waydroid | Android 13 + GAPPS в LXC-контейнере |
| Лаунчер для Game Mode | `waydroid-gamemode` — позволяет добавить Waydroid в Steam как стороннюю игру |
| Поддержка геймпада | Правый стик корректно маппируется для Android-игр; геймпады, подключённые до запуска сессии, подхватываются автоматически (Game Mode и Desktop Mode) |
| Модуль binder | Ядра SteamOS начиная с 6.18 собраны без binder — `waydroid-setup` собирает штатный in-tree binder под текущее ядро (исходники с kernel.org + небольшая прослойка через kallsyms, без патчей драйвера); пропускается, если binder встроен в ядро |
| ARM-трансляция | libhoudini через [casualsnek/waydroid_script](https://github.com/casualsnek/waydroid_script) |

## Требования

- SteamOS 3.5 и выше
- ~3 ГБ свободного места на встроенном накопителе под образ Android

## Использование

Установите Nix, если ещё не установлен ([NixOS/nix-installer](https://github.com/NixOS/nix-installer), автоматически определяет SteamOS):

```bash
curl -sSfL https://artifacts.nixos.org/nix-installer | sh -s -- install --enable-flakes
```

Клонировать и применить:

```bash
git clone https://github.com/Labaman/SteamOS-Waydroid-Nix-Installer ~/.config/home-manager
nix run home-manager/master -- switch
```

Первый запуск берёт Home Manager прямо с GitHub через `nix run` — отдельно ставить его не нужно. После этого команда `home-manager` уже будет в профиле, и дальше достаточно запускать просто `home-manager switch`.

Если файл конфигурации, которым должен управлять Home Manager, уже существует (например, `~/.bashrc` при включении bash), он будет переименован в `<файл>.hm-backup`. Если такая копия уже есть, `switch` остановится: удалите или переименуйте старую копию и запустите его снова.

Затем откройте новое окно терминала: текущее запущено до `switch`, поэтому в его `PATH` ещё нет `~/.local/bin`, куда установлены `nix-gpu-setup` и `waydroid-setup`.

Настройте GPU-драйверы для Nix GUI-приложений (спросит пароль sudo; перезапускать, когда `switch` предупреждает, что драйверы требуют обновления):

```bash
nix-gpu-setup
```

Затем запустите скрипт установки Waydroid один раз (~3 ГБ для образа Android):

```bash
waydroid-setup
```

`waydroid-setup` необходимо перезапускать после каждого обновления SteamOS или образа Waydroid — уже выполненные шаги пропускаются автоматически, а «затёртые» обновлением изменения будут восстановлены.

Свои пакеты и программы добавляйте в `home.nix` под комментарием `# Add your own packages here`.

## Waydroid в Game Mode

После завершения `waydroid-setup` добавьте Waydroid в Steam:

**Desktop Mode** → Игры → Добавить игру не из Steam → Обзор → `~/.local/bin/waydroid-gamemode` → переименуйте в «Waydroid»

Затем включите встроенную поддержку сенсорного экрана в настройках контроллера для ярлыка Waydroid:

Изменить раскладку → Наборы действий → По умолчанию → Добавить всегда включённую команду → Система → Встр. поддержка сенсорного экрана

## Оболочка

bash (оболочка входа SteamOS) включён в `home.nix` по умолчанию. Он подключает переменные сессии и строку приглашения Starship, а также добавляет в `PATH` каталог `~/.local/bin`, куда устанавливаются `waydroid-setup` и другие скрипты. Существующие `~/.bashrc` и `~/.bash_profile` переименовываются в `*.hm-backup`.
Чтобы использовать zsh или fish, нужно сменить логин-шелл — шаги и сравнение оболочек в [nix-hm-conf-steamos](https://github.com/Labaman/nix-hm-conf-steamos).

## Благодарности

- [ryanrudolfoba/SteamOS-Waydroid-Installer](https://github.com/ryanrudolfoba/SteamOS-Waydroid-Installer) — подход с cage-лаунчером для Game Mode и udev/uevent пропсы из `waydroid_base.prop`
- [Bazzite](https://github.com/ublue-os/bazzite) — паттерн uevent-ретриггера для поддержки геймпада
- [casualsnek/waydroid_script](https://github.com/casualsnek/waydroid_script) — установщик libhoudini (ARM-трансляция)
- Linux kernel `drivers/android` — GPL-2.0 — штатный in-tree binder; исходники берутся при сборке с kernel.org под версию текущего ядра
- The Android Open Source Project — раскладка правого стика (Apache-2.0)

## Лицензия

Под **GNU General Public License v3.0 или новее** (GPL-3.0-or-later) — см. [LICENSE](LICENSE).

Атрибуции сторонних материалов — в [NOTICE](NOTICE). Рантайм-зависимости (Waydroid, waydroid_script, ARM-трансляторы) скачиваются или вызываются при установке и сохраняют свои лицензии — в репозитории они не бандлятся.
