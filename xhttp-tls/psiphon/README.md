# psiphon/

`psiphon_install.sh` — установщик **vps-psiphon** (Psiphon как egress для узла Xray/Remnawave), лицензия MIT
(Chara Freedom, файл `LICENSE` рядом). Файл лежит **без изменений** и вшивается в `install.sh` сборкой
(`python3 build.py`); установщик запускает его с `--socks-port <свой порт> --no-http`.

- Источник: https://github.com/Chara-Freedom/vps-psiphon (архив `vps-psiphon-main.zip`, переданный владельцем проекта)
- SHA-256 `psiphon_install.sh`: `e41b9aeed9f5f11a2a6f1fe2103a74e075f1703a01bc4d1e5cf734e8cf30f4f3`
- Образ контейнера, который скрипт ставит по умолчанию: `swarupsengupta2007/psiphon:latest` (сторонний, без закрепления версии)

Обновить файл: заменить `psiphon_install.sh`, пересчитать SHA-256 здесь, пересобрать `install.sh`.
