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
