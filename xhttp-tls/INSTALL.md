# XHTTP + TLS нода — установка

Схема: клиент → `<домен>:443` (TLS, h2) → nginx →
`/api/v2/telemetry/` → Xray `127.0.0.1:10443` (XHTTP, security none).
Всё остальное nginx отдаёт как сайт-заглушку.

## Установка (на VPS, от root)

```
bash <(curl -fsSL https://raw.githubusercontent.com/goji-app/goji-node-setup/main/xhttp-tls/install.sh)
```

Скрипт спросит домен, SECRET_KEY ноды, NODE_PORT, IP панели и e-mail.
Всё можно передать флагами: `install.sh <домен> --secret-key ... --node-port 2222 --panel-ip ... --email ... --template blog`

Заглушка выбирается случайно из `templates/` (analytics, blog, docs, saas), при повторном запуске сохраняется. После правок в `templates/` — `python build.py`.

Перед запуском: A-запись домена указывает на этот VPS, нода добавлена в панели.

## Усиление защиты и тюнинг (включено по умолчанию)

Скрипт после установки ноды настраивает сервер (best-effort: сбой отдельного шага даёт предупреждение, а не остановку):

- **BBR + fq** — только если ядро поддерживает bbr (`/etc/sysctl.d/99-goji-tuning.conf`).
- **Auto tuning** — sysctl: буферы, backlog, somaxconn, keepalive, TCP Fast Open, conntrack, rp_filter, отключение redirects/source-route.
- **Traffic Control** — `goji-tc.service`: qdisc fq на интерфейсе с маршрутом по умолчанию (не в контейнерах).
- **ZRAM** — `goji-zram.service`, 50% RAM, zstd (fallback lz4); настройки в `/etc/default/goji-zram` (не в контейнерах).
- **UFW** — deny incoming / allow outgoing; открыты SSH, 80, 443, порт ноды (только с `--panel-ip`, если он задан) и порты, которые сейчас слушает xray.
- **Fail2ban** — jail `sshd` и `recidive` (`/etc/fail2ban/jail.d/goji.local`), IP панели в игнор-листе.
- **ICMP** — входящий echo-request ограничен до 5/сек (остальной ICMP не трогается, чтобы работал PMTUD); `--icmp-drop` — полная блокировка. Бэкапы: `/etc/ufw/before*.rules.goji-bak`.

Флаги: `--skip-hardening`, `--icmp-drop`, `--ssh-port N`, `--allow-port 8443[/tcp|/udp]` (повторяемый).

> Если в профиле Xray есть inbound на порту, отличном от 443, и он не слушался на момент установки — добавьте его через `--allow-port`, иначе UFW его закроет.
> Скрипт не тестировался на реальном VPS в этой сессии — сначала проверьте на тестовом сервере и держите открытой вторую SSH-сессию.

## Профиль Xray в Remnawave

`xray-node-profile.json` — универсальный профиль (inbound `XHTTP-TLS`,
127.0.0.1:10443). Создать его один раз в панели и назначить нодам.
Пока на 443 висит старый профиль, скрипт ждёт до 15 минут.

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
