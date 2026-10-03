# XHTTP + TLS нода — установка

Схема: клиент → `<домен>:443` (TLS, h2) → nginx →
`/api/v2/telemetry/` → Xray `127.0.0.1:10443` (XHTTP, security none).
Всё остальное nginx отдаёт как сайт-заглушку.

## Установка (на VPS, от root)

```
bash <(curl -fsSL https://raw.githubusercontent.com/goji-app/goji-node-setup/main/xhttp-tls/install.sh)
```

Первым вопросом покажет меню выбора сайта-заглушки, затем спросит домен, SECRET_KEY ноды, NODE_PORT, IP панели и e-mail. Все сообщения на русском.
Всё можно передать флагами: `install.sh <домен> --secret-key ... --node-port 2222 --panel-ip ... --email ... --template blog`

Заглушка выбирается в меню (на терминале) или флагом `--template <имя>`; без терминала и без флага — случайная. Доступны: analytics, blog, docs, saas, freelancer, resume, creative, grayscale, new-age, agency. При повторном запуске выбранная заглушка сохраняется. Сменить позже: `goji-node decoy` (меню) или `goji-node decoy <имя|random>`; шаблоны хранятся в `/usr/share/goji-node/templates`. Источники и лицензии: `templates/README.md`. После правок в `templates/` — `python build.py`.

Перед запуском: A-запись домена указывает на этот VPS, нода добавлена в панели.

## Усиление защиты и тюнинг (включено по умолчанию)

Скрипт после установки ноды настраивает сервер (best-effort: сбой отдельного шага даёт предупреждение, а не остановку):

- **BBR + fq** — только если ядро поддерживает bbr (`/etc/sysctl.d/99-goji-tuning.conf`).
- **Auto tuning** — sysctl: буферы, backlog, somaxconn, keepalive, TCP Fast Open, conntrack, rp_filter, отключение redirects/source-route.
- **tc fq** — `goji-tc.service`: qdisc fq на интерфейсе с маршрутом по умолчанию (не в контейнерах).
- **ZRAM** — `goji-zram.service`, 50% RAM, zstd (fallback lz4); настройки в `/etc/default/goji-zram` (не в контейнерах).
- **UFW** — deny incoming / allow outgoing; открыты SSH, 80, 443, порт ноды (только с `--panel-ip`, если он задан) и порты, которые сейчас слушает xray.
- **Fail2ban** — jail `sshd` и `recidive` (`/etc/fail2ban/jail.d/goji.local`), IP панели в игнор-листе.
- **SSH** — drop-in `/etc/ssh/sshd_config.d/00-goji-hardening.conf`: `MaxAuthTries 4`, `LoginGraceTime 30`, запрет agent/tunnel/X11 forwarding и `GatewayPorts`. Способ входа, `PermitRootLogin` и `AllowTcpForwarding` не меняются: скрипт сравнивает `sshd -T` до и после и при любом расхождении или ошибке откатывает файл (копии в `/var/backups/goji-node`). Если вы ходите через `ssh -A` (agent forwarding), добавьте исключение сами.
- **Защита от ping** — nftables-таблица `inet goji_privacy` (`goji-two-way-ping.service`, поднимается до `network-pre.target`): входящий echo-request (IPv4/IPv6) ограничен до 5/сек, ICMP timestamp-request блокируется; `--icmp-drop` — полная блокировка echo. Исходящий ping, ICMP-ошибки, PMTUD и IPv6 neighbour discovery не затрагиваются. Режим: `/etc/default/goji-two-way-ping`. Правила старых версий в `/etc/ufw/before*.rules` (метка `goji-icmp`) удаляются. Пакет `nftables` ставится до любых правил файрвола, а его собственная служба `nftables.service` (на загрузке делает `flush ruleset`) отключается, если пакета раньше не было.
- **Traffic Control (по желанию)** — `--traffic-control` (или ответ `y` на вопрос при установке). Таблица nftables `inet goji_guard` блокирует новые входящие соединения из сетей публичных списков [shadow-netlab/traffic-guard-lists](https://github.com/shadow-netlab/traffic-guard-lists) (`antiscanner`, `government_networks`, `skipa`). Исключены: loopback, уже установленные соединения, IP администратора (адрес текущей SSH-сессии и `--admin-ip`), IP панели, порт SSH и TCP/80 (чтобы не сломать продление сертификата). Списки обновляются раз в сутки (`goji-guard-update.timer`), хранятся локально, при сбое загрузки остаётся последняя рабочая копия. Из списка отбрасываются слишком широкие сети (шире /8 для IPv4, /16 для IPv6) и приватные диапазоны; список с мусором (>5% строк не IP/CIDR) отклоняется целиком. Управление: `goji-guard status | update | on | off`. Списки — сторонние, их состав вы не контролируете: оцените, не заденет ли он ваших пользователей.

Флаги: `--skip-hardening`, `--icmp-drop`, `--ssh-port N`, `--allow-port 8443[/tcp|/udp]` (повторяемый), `--traffic-control` / `--no-traffic-control`, `--admin-ip IP` (повторяемый).

> Если в профиле Xray есть inbound на порту, отличном от 443, и он не слушался на момент установки — добавьте его через `--allow-port`, иначе UFW его закроет.
> Скрипт не тестировался на реальном VPS в этой сессии — сначала проверьте на тестовом сервере и держите открытой вторую SSH-сессию.

## Обновление ОС

`--upgrade-os` (или ответ `Y` на вопрос при установке; без терминала по умолчанию пропускается, `--no-upgrade-os` — не обновлять) выполняет `apt update` и `apt upgrade` для **текущего релиза** Ubuntu/Debian до установки nginx и остальных пакетов. Переход на новый релиз (`do-release-upgrade`) скрипт не делает. Перед установкой план симулируется: если он удаляет хоть один пакет, обновление не выполняется (только предупреждение). Изменённые вами конфиги сохраняются (`--force-confold`), `needrestart` не перезапускает службы сам. Если после обновления нужна перезагрузка (ядро, libc), скрипт предупредит, `goji-node-check` покажет строку «Перезагрузка»; перезагрузитесь, когда удобно, затем `--resume`.

## Меню goji-node, проверка, продолжение, версия

Если сервер уже настраивался этим скриптом, запуск `install.sh` без параметров на терминале сначала спрашивает, что сделать: проверить настройки сервера, показать установленные настройки (из `/etc/goji-node/install.conf`), открыть меню `goji-node` или переустановить заново (тогда в меню заглушки Enter оставляет текущую). Там же есть пункт «Удалить компоненты установки». Без меню: `bash install.sh --settings`, `bash install.sh --uninstall`.

После установки доступна команда `goji-node` (от root): меню с пунктами — полная проверка настроек; установленные настройки (с чем ставился сервер); отдельные проверки (сайт и сертификат, нода и Xray, система, защита); открытые порты и правила UFW; готовый профиль для Remnawave; смена сайта-заглушки; проверка автопродления сертификата (`certbot renew --dry-run`). Те же действия без меню: `goji-node check [web|node|system|security|all]`, `goji-node settings`, `goji-node uninstall`, `goji-node ports`, `goji-node profile`, `goji-node decoy [имя]`. Проверка помечает строки: ✓ — в порядке, ! — замечание, ✗ — ошибка.

```
bash install.sh --version      # версия установщика
goji-node                      # меню; goji-node check — полный отчёт (то же: goji-node-check, install.sh --check)
bash install.sh --resume       # повторить установку с сохранёнными параметрами (/etc/goji-node/install.conf)
```

### Автоисправление

`install.sh --fix` (или `goji-node fix`, пункт 12 меню; `--dry-run` — только показать план) находит известные проблемы и исправляет безопасные:

| Проблема | Что делает |
|---|---|
| нет файла профиля / шаблонов (сервер ставился старой версией) | восстанавливает |
| контейнер ноды остановлен | `docker compose up -d` в `/opt/remnanode` |
| nginx остановлен | `systemctl enable --now nginx` |
| сертификат истёк или осталось ≤ 14 дн. | `certbot renew --force-renewal` + reload nginx |
| `certbot.timer`, Fail2ban, защита от ping, Traffic Control не работают | запускает/загружает |
| пустой сайт-заглушка | разворачивает прежний или случайный шаблон |
| TLS-фронт не включён при активном профиле, нет сертификата, конфиг nginx сломан нашим файлом, UFW выключен | повторный проход установки (`--resume`) с сохранёнными настройками; только в `install.sh --fix` |

Сам **не меняет**: чужой сервис на :443 (печатает, кто занял порт и что сделать), профиль в панели Remnawave (его нужно вставить вручную), чужой конфиг nginx, SSH-доступ.

Коды `--check` и самой установки: `0` — всё в порядке; `1` — есть ошибка; `2` — всё установлено, но профиль XHTTP в панели ещё не применён (после переключения профиля запустите `--resume`). `130`/`143` — прерывание (Ctrl+C / TERM). `--resume` не переустанавливает уже работающую ноду и берёт `SECRET_KEY` из существующего compose-файла; параметры `SECRET_KEY` в `install.conf` не хранятся. Параллельный запуск блокируется (`/run/goji-node-setup.lock`).

Перед установкой проверяются: systemd, ОС (Debian 12/13, Ubuntu 22.04/24.04 — на других предупреждение), архитектура, свободное место (≥1 GiB) и занятость порта 80.

## Удаление компонентов

`bash install.sh --uninstall` (или пункт меню «Удалить компоненты установки», или `goji-node uninstall`) показывает список и удаляет только отмеченное, после подтверждения словом «удалить»:

| Компонент | Что делается |
|---|---|
| Сайт и nginx | удаляются конфиги `xhttp-tls.conf`, `xhttp-acme.conf`, сайт-заглушка и каталог ACME; nginx перезагружается (пакет остаётся) |
| Сертификат | `certbot delete` для вашего домена; выбирается вместе с сайтом, потому что nginx ссылается на сертификат |
| Remnawave Node | `docker compose down`, контейнер удаляется, `/opt/remnanode` переносится в `/var/backups/goji-node/remnanode-<дата>` (права 700, там compose с `SECRET_KEY`). **Нода отключится от панели** |
| Защита от ping | служба, правила nftables `goji_privacy`, скрипт и `/etc/default/goji-two-way-ping` |
| Traffic Control | службы и таймер `goji-guard*`, таблица nftables, `/etc/goji-guard`, `/var/lib/goji-guard` |
| Тюнинг | `goji-tc`, `goji-zram`, sysctl-файл и modules-load; значения sysctl и qdisc возвращаются полностью только после перезагрузки |
| Усиление SSH | удаляется `sshd_config.d/00-goji-hardening.conf`, после `sshd -t` sshd перечитывает конфигурацию |
| Fail2ban | удаляется `jail.d/goji.local` |
| Правила UFW | удаляются 80/tcp, 443/tcp, правила порта ноды и `--allow-port`; SSH и политика по умолчанию не трогаются. Скрипт не помнит, какие правила были у вас до установки: если 80/443 нужны другим сервисам, не отмечайте этот пункт |
| goji-node и настройки | `/usr/local/sbin/goji-node*`, `/etc/goji-node`, `/usr/share/goji-node` |

Пакеты (nginx, certbot, docker, ufw, fail2ban, nftables, python3) не удаляются, копии в `/var/backups/goji-node` остаются. Без меню: `goji-node uninstall [--yes] [site cert node ping guard tuning ssh fail2ban ufw tools | all]`.

## Профиль Xray в Remnawave

`xray-node-profile.json` — универсальный профиль (inbound `XHTTP-TLS`,
127.0.0.1:10443). Создать его один раз в панели и назначить нодам.
Пока на 443 висит старый профиль, скрипт ждёт до 15 минут.

В конце установки скрипт **выводит готовый профиль** (JSON с вашими портом и путём): скопируйте всё между линиями «начало» и «конец» в Remnawave → Config Profiles → «+» → вставьте → Save, затем назначьте профиль ноде. Если профиль ещё не активен, JSON выводится до ожидания, чтобы его можно было вставить сразу. Копия: `/etc/goji-node/remnawave-profile.json`; показать снова: `goji-node profile`.

## Хост в Remnawave

| Поле | Значение |
|---|---|
| Адрес / порт | <домен> / 443 |
| Network | xhttp |
| Path | /api/v2/telemetry/ |
| Mode | auto |
| Security | tls |
| SNI | <домен> |
| ALPN | h2 |
| Fingerprint | firefox |
| Flow | пусто |

## Проверка

- `curl -sI https://<домен>/` → 200
- `curl -sI https://<домен>/nope` → 404
- клиент с новым хостом → `2ip.io` показывает IP ноды
