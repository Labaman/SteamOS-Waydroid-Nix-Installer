# SteamOS-Waydroid-Nix-Installer

[English](README.md) | **Русский**

Устанавливает [Waydroid](https://waydroid.io/) (Android 13 + GAPPS) на Steam Deck через Nix + Home Manager.

Делает всё то же, что [nix-hm-conf-steamdeck](https://github.com/Labaman/nix-hm-conf-steamdeck) — базовые фиксы SteamOS, nixGL, строка приглашения оболочки, Wayland — плюс устанавливает Android в LXC-контейнере с лаунчером для Game Mode и поддержкой геймпада.

Поддерживает SteamOS 3.5–3.8. Пакеты и настройки не слетают при обновлениях SteamOS.

## Возможности

| Фикс / Фича | Описание |
|-------------|----------|
| Базовые фиксы SteamOS | Подробнее: [nix-hm-conf-steamdeck](https://github.com/Labaman/nix-hm-conf-steamdeck) |
| Waydroid | Android 13 + GAPPS в LXC-контейнере |
| Лаунчер для Game Mode | `waydroid-gamemode` — добавить в Steam как стороннюю игру |
| Поддержка геймпада | Правый стик корректно маппируется для Android-игр |
| ARM-трансляция | libhoudini через [casualsnek/waydroid_script](https://github.com/casualsnek/waydroid_script) |

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

## Смена оболочки (опционально)

Управляемая оболочка нужна, чтобы переменные сессии (фиксы выше) попадали в графическую сессию. Раскомментируй один из блоков в `home.nix`.

| Оболочка | Покрытие переменных сессии | Примечания |
|----------|---------------------------|------------|
| **bash** | login + интерактивные шеллы | Дефолт SteamOS; проще всего начать. Две строки `# bash only` в `home.nix` закрывают брешь в non-interactive запусках. |
| **zsh** | login, интерактивный и non-interactive | `.zshenv` сорсится при каждом запуске zsh — переменные сессии загружаются всегда, без доп. костылей. Не трогает bash-дотфайлы. Строки `# bash only` можно удалить. |
| **fish** | login, интерактивный и non-interactive | Автодополнение, подсказки команд и подсветка синтаксиса работают из коробки без доп. настройки. Не трогает bash-дотфайлы. Строки `# bash only` можно удалить. Важно: fish не совместим с POSIX/bash — bash-скрипты не запустятся напрямую внутри fish. |

### Смена дефолтного логин-шелла

Рекомендуется сменить дефолтный bash на zsh или fish — их модули HM развиваются активнее и отпадает необходимость в специфичных для bash костылях.

При смене оболочки следует указывать **системный** бинарь, а не Nix-managed — тогда логин останется рабочим даже если Nix будет удалён (оба шелла идут в комплекте с SteamOS):

Переключиться на **zsh**:
```bash
chsh -s /usr/bin/zsh
```

Переключиться на **fish**:
```bash
chsh -s /usr/bin/fish
```

Сделай это **до** запуска `home-manager switch` с включённым модулем оболочки. После перезахода в сессию раскомментируй соответствующий блок в `home.nix`.
