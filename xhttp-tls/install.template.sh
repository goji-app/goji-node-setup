#!/usr/bin/env bash
# XHTTP + TLS front for a Remnawave node: nginx (TLS, decoy site) -> Xray XHTTP.
#
# Использование:
#   bash install.sh [домен] [--email you@example.com] [--xray-port 10443]
#                            [--path /api/v2/telemetry/] [--wait 900]
#                            [--secret-key KEY] [--node-port 2222]
#                            [--panel-ip 1.2.3.4] [--skip-node]
#                            [--template random|analytics|blog|docs|saas|freelancer|resume|
#                                        creative|grayscale|new-age|agency]
#                            [--skip-hardening] [--icmp-drop] [--ssh-port N]
#                            [--allow-port 8443[/tcp|/udp]]...
#                            [--traffic-control|--no-traffic-control] [--admin-ip IP]...
#                            [--upgrade-os|--no-upgrade-os]
#                            [--panel-url https://panel.example.com] [--panel-node NAME]
#                            [--panel-profile NAME] [--panel-host REMARK] [--panel-squad NAME]...
#                            [--panel-overwrite-profile] [--no-panel]   (токен: env GOJI_PANEL_TOKEN)
#   bash install.sh --check | --resume | --version
# После установки: goji-node — меню проверки, профиль для Remnawave, смена заглушки.
#
# Переустанавливает Remnawave Node (docker, /opt/remnanode), спрашивая SECRET_KEY и т. д.
# Профиль Xray задаётся в Remnawave: переключите профиль ноды на XHTTP
# (слушает 127.0.0.1:<xray-port>, security none) — скрипт ждёт освобождения
# порта 443 и затем включает TLS-фронт. Готовый профиль выводится в конце установки.
set -euo pipefail

VERSION=1.2.0
CONF_FILE=/etc/goji-node/install.conf
DOMAIN=""
EMAIL=""
XRAY_PORT=10443
XPATH="/api/v2/telemetry/"
WAIT=900
SECRET_KEY=""
NODE_PORT=""
PANEL_IP=""
SKIP_NODE=0
TEMPLATE=""
NODE_DIR=/opt/remnanode
HARDEN=1
ICMP_DROP=0
SSH_PORT=""
EXTRA_PORTS=()
ADMIN_IPS=()
GUARD_MODE=""
GUARD_ON=0
UPGRADE_MODE=""
UPGRADE_ON=0
PANEL_URL=""
PANEL_TOKEN="${GOJI_PANEL_TOKEN:-}"
PANEL_NODE=""
PANEL_PROFILE="Goji XHTTP-TLS"
PANEL_HOST=""
PANEL_SQUADS=()
PANEL_OVERWRITE=0
PANEL_MODE=""
PANEL_DONE=0
PROFILE_SHOWN=0
RESUME=0
CHECK=0

die()  { echo -e "\e[31m[x] $*\e[0m" >&2; exit 1; }
info() { echo -e "\e[36m[*] $*\e[0m"; }
ok()   { echo -e "\e[32m[+] $*\e[0m"; }
warn() { echo -e "\e[33m[!] $*\e[0m"; }

# ---------------------------------------------------------------- component report, menu
# Everything between here and "end of shared block" is also installed as /usr/local/sbin/goji-node
# (see install_check_command, "declare -f"): the interactive menu and `goji-node check|profile|decoy`.
# check exit codes: 0 all good, 1 something is broken, 2 installed but the Xray profile is not active yet.
GOJI_ETC=/etc/goji-node
GOJI_SHARE=/usr/share/goji-node
GOJI_WEBROOT=/var/www/decoy

gj_row() { # gj_row <status ok|warn|fail> <component> <detail>
  local c=$'\e[32m✓\e[0m' w=$'\e[33m!\e[0m' f=$'\e[31m✗\e[0m' mark pad
  case "$1" in ok) mark=$c ;; warn) mark=$w; GJ_WARN=$((${GJ_WARN:-0} + 1)) ;; *) mark=$f ;; esac
  pad=$((34 - ${#2})); (( pad < 1 )) && pad=1
  printf ' %s %s%*s %s\n' "$mark" "$2" "$pad" "" "$3"
}

gj_title() { echo; echo "$1"; echo "----------------------------------------------------------------"; }

# Загрузка сохранённых настроек установки; обнуляет счётчики итога.
gjc_load() {
  export LC_ALL=C.UTF-8
  [[ -r $GOJI_ETC/install.conf ]] || { echo "Нет сохранённой установки ($GOJI_ETC/install.conf). Сначала запустите install.sh." >&2; return 1; }
  # shellcheck disable=SC1090,SC1091
  . "$GOJI_ETC/install.conf"
  GJ_FAIL=0; GJ_PENDING=0; GJ_WARN=0
  GJ_LIVE="/etc/letsencrypt/live/$GOJI_DOMAIN"
}

# Описание заглушки для меню (на русском).
goji_tpl_desc() {
  case "$1" in
    analytics)  echo "Аналитика: панель с графиками (написана для этого репозитория)" ;;
    blog)       echo "Блог: личный блог со списком записей" ;;
    docs)       echo "Документация: одностраничный справочник с боковым меню" ;;
    saas)       echo "SaaS: лендинг облачного сервиса с тарифами" ;;
    freelancer) echo "Фрилансер: портфолио с галереей работ" ;;
    resume)     echo "Резюме: страница-визитка разработчика" ;;
    creative)   echo "Креатив: яркий лендинг студии на полный экран" ;;
    grayscale)  echo "Grayscale: тёмный минималистичный лендинг" ;;
    new-age)    echo "New Age: лендинг мобильного приложения" ;;
    agency)     echo "Агентство: корпоративный сайт с командой и услугами" ;;
    *)          echo "Своя заглушка" ;;
  esac
}

gjc_web() {
  local code end days
  gj_title "Сайт, сертификат и nginx — $GOJI_DOMAIN"
  if systemctl is-active --quiet nginx 2>/dev/null; then gj_row ok "nginx" "работает"; else gj_row fail "nginx" "не запущен"; GJ_FAIL=1; fi
  if nginx -t >/dev/null 2>&1; then gj_row ok "Конфигурация nginx" "nginx -t без ошибок"; else gj_row fail "Конфигурация nginx" "nginx -t сообщает об ошибке"; GJ_FAIL=1; fi

  if [[ -f $GJ_LIVE/fullchain.pem ]]; then
    end=$(openssl x509 -enddate -noout -in "$GJ_LIVE/fullchain.pem" 2>/dev/null | cut -d= -f2)
    days=$(( ( $(date -d "$end" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
    if (( days > 14 )); then gj_row ok "Сертификат Let's Encrypt" "действует ещё $days дн."
    elif (( days > 0 )); then gj_row warn "Сертификат Let's Encrypt" "осталось $days дн. — проверьте продление"
    else gj_row fail "Сертификат Let's Encrypt" "истёк или не читается"; GJ_FAIL=1; fi
  else
    gj_row fail "Сертификат Let's Encrypt" "файл не найден"; GJ_FAIL=1
  fi
  if grep -qs "authenticator = webroot" "/etc/letsencrypt/renewal/$GOJI_DOMAIN.conf"; then
    gj_row ok "Продление сертификата" "webroot, certbot.timer: $(systemctl is-active certbot.timer 2>/dev/null || echo unknown)"
  else
    gj_row warn "Продление сертификата" "конфигурация webroot не найдена"
  fi

  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 --resolve "$GOJI_DOMAIN:443:127.0.0.1" "https://$GOJI_DOMAIN/" 2>/dev/null || true)
  if [[ $code == 200 ]]; then gj_row ok "HTTPS :443, сайт-заглушка" "HTTP 200"; else gj_row fail "HTTPS :443, сайт-заглушка" "$([[ -z $code || $code == 000 ]] && echo нет ответа || echo "HTTP $code")"; GJ_FAIL=1; fi
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 --resolve "$GOJI_DOMAIN:443:127.0.0.1" "https://$GOJI_DOMAIN/goji-check-nope" 2>/dev/null || true)
  if [[ $code == 404 ]]; then gj_row ok "Неизвестный путь" "HTTP 404"; else gj_row warn "Неизвестный путь" "$([[ -z $code || $code == 000 ]] && echo нет ответа || echo "HTTP $code"), ожидался 404"; fi
  if [[ -f $GOJI_WEBROOT/.template ]]; then gj_row ok "Заглушка" "$(cat "$GOJI_WEBROOT/.template") — $(goji_tpl_desc "$(cat "$GOJI_WEBROOT/.template")")"; else gj_row warn "Заглушка" "не определена"; fi
}

gjc_node() {
  local v
  gj_title "Нода Remnawave и Xray"
  if ss -Hltn "sport = :$GOJI_XRAY_PORT" 2>/dev/null | grep -q .; then
    gj_row ok "Xray XHTTP 127.0.0.1:$GOJI_XRAY_PORT" "слушает"
  else
    gj_row warn "Xray XHTTP 127.0.0.1:$GOJI_XRAY_PORT" "профиль в панели ещё не применён"; GJ_PENDING=1
  fi
  if [[ -n ${GOJI_NODE_PORT:-} ]]; then
    if command -v docker >/dev/null && [[ "$(docker inspect -f '{{.State.Running}}' remnanode 2>/dev/null)" == true ]]; then
      v=$(docker inspect -f '{{.Config.Image}}' remnanode 2>/dev/null)
      gj_row ok "Remnawave Node (docker)" "запущен, образ: ${v##*/}"
    else
      gj_row fail "Remnawave Node (docker)" "контейнер remnanode не запущен"; GJ_FAIL=1
    fi
    if ss -Hltn "sport = :$GOJI_NODE_PORT" 2>/dev/null | grep -q .; then gj_row ok "API ноды :$GOJI_NODE_PORT" "слушает"; else gj_row warn "API ноды :$GOJI_NODE_PORT" "порт не слушается"; fi
  else
    gj_row warn "Remnawave Node (docker)" "не устанавливался этим скриптом (--skip-node)"
  fi
  if [[ -n ${GOJI_PANEL_URL:-} ]]; then gj_row ok "Панель Remnawave" "автонастройка: $GOJI_PANEL_URL (goji-panel sync)"; else gj_row warn "Панель Remnawave" "профиль и хост создаются вручную (пункт «Профиль для Remnawave»)"; fi
}

gjc_system() {
  local v q up
  gj_title "Система: тюнинг и обновления"
  if [[ ${GOJI_HARDEN:-1} -ne 1 ]]; then gj_row warn "Усиление защиты и тюнинг" "пропущены (--skip-hardening)"; else
    v=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null); q=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    if [[ $v == bbr && $q == fq ]]; then gj_row ok "BBR + fq" "включены"; else gj_row warn "BBR + fq" "сейчас: ${v:-?} + ${q:-?}"; fi
    if swapon --noheadings 2>/dev/null | grep -q zram; then gj_row ok "ZRAM" "swap на zram активен"; else gj_row warn "ZRAM" "не активен (контейнер или отключён)"; fi
  fi
  gj_row ok "Память / диск" "$(free -h | awk '/^Mem:/{print "RAM занято "$3" из "$2}'); диск / занят $(df -P / | awk 'NR==2{print $5}')"
  up=$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)
  gj_row ok "Время работы" "$((up / 86400)) дн. $((up % 86400 / 3600)) ч $((up % 3600 / 60)) мин"
  if [[ -f /var/run/reboot-required ]]; then gj_row warn "Перезагрузка" "нужна для применения обновлений ОС"; else gj_row ok "Перезагрузка" "не требуется"; fi
}

gjc_security() {
  gj_title "Защита: UFW, Fail2ban, SSH, ping, Traffic Control"
  if [[ ${GOJI_HARDEN:-1} -ne 1 ]]; then gj_row warn "Усиление защиты" "пропущено (--skip-hardening)"; return 0; fi
  if ufw status 2>/dev/null | grep -q "Status: active"; then gj_row ok "UFW" "включён, входящие закрыты по умолчанию"; else gj_row warn "UFW" "не включён"; fi
  if fail2ban-client ping >/dev/null 2>&1; then gj_row ok "Fail2ban" "работает (sshd, recidive)"; else gj_row warn "Fail2ban" "не отвечает"; fi
  if [[ -f /etc/ssh/sshd_config.d/00-goji-hardening.conf ]] && sshd -T 2>/dev/null | grep -qx "maxauthtries 4"; then
    gj_row ok "SSH" "ограничения применены (способ входа не менялся)"
  else
    gj_row warn "SSH" "ограничения не применены"
  fi
  if nft list table inet goji_privacy >/dev/null 2>&1; then
    gj_row ok "Защита от ping" "echo-request: $(grep -qs 'MODE=drop' /etc/default/goji-two-way-ping && echo блок || echo 'лимит 5/с'), timestamp: блок"
  else
    gj_row warn "Защита от ping" "правила nftables не загружены"
  fi
  if [[ ${GOJI_GUARD:-0} -eq 1 ]]; then
    if nft list table inet goji_guard >/dev/null 2>&1; then gj_row ok "Traffic Control" "списки применены (goji-guard status)"; else gj_row warn "Traffic Control" "таблица не загружена (goji-guard update)"; fi
  else
    gj_row warn "Traffic Control" "не устанавливался (--traffic-control)"
  fi
}

gjc_summary() {
  echo "----------------------------------------------------------------"
  if (( GJ_FAIL )); then echo "Итог: есть ошибки."; return 1; fi
  if (( GJ_PENDING )); then echo "Итог: всё установлено, ожидается применение профиля XHTTP в Remnawave."; return 2; fi
  if (( GJ_WARN )); then echo "Итог: ошибок нет, замечаний: $GJ_WARN (см. строки с «!»)."; else echo "Итог: всё в порядке."; fi
  return 0
}

# goji_check [web|node|system|security|all]; код возврата: 0 / 1 / 2
goji_check() {
  gjc_load || return 1
  case "${1:-all}" in
    web)      gjc_web ;;
    node)     gjc_node ;;
    system)   gjc_system ;;
    security) gjc_security ;;
    all|*)    gjc_web; gjc_node; gjc_system; gjc_security ;;
  esac
  gjc_summary
}

# Открытые порты и правила файрвола.
goji_ports() {
  gj_title "Открытые порты (слушающие сокеты)"
  ss -Hltnup 2>/dev/null | awk '{printf "  %-5s %-28s %s\n", $1, $5, $7}' | sort -u
  gj_title "Правила UFW"
  if command -v ufw >/dev/null; then ufw status verbose 2>/dev/null | sed 's/^/  /'; else echo "  ufw не установлен"; fi
}

# Печатает JSON профиля Remnawave (порт и path подставлены из настроек установки).
goji_render_profile() {
  local f=$GOJI_SHARE/xray-node-profile.json
  [[ -r $f ]] || { echo "Нет файла профиля $f" >&2; return 1; }
  command -v python3 >/dev/null || { echo "Нужен python3 (apt-get install python3-minimal)" >&2; return 1; }
  python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
ib = cfg["inbounds"][0]
ib["port"] = int(sys.argv[2])
ib["streamSettings"]["xhttpSettings"]["path"] = sys.argv[3]
print(json.dumps(cfg, indent=2, ensure_ascii=False))
' "$f" "$GOJI_XRAY_PORT" "$GOJI_XPATH"
}

# Готовый профиль для вставки в Remnawave: Config Profiles → создать → вставить JSON.
goji_show_profile() {
  gjc_load || return 1
  local out=$GOJI_ETC/remnawave-profile.json
  goji_render_profile > "$out.tmp" || { rm -f "$out.tmp"; return 1; }
  mv -f "$out.tmp" "$out"; chmod 644 "$out"
  echo
  echo "ГОТОВЫЙ ПРОФИЛЬ ДЛЯ REMNAWAVE"
  echo "Скопируйте всё между линиями (он же сохранён в $out)."
  echo "Панель → Config Profiles → «+» → имя «${GOJI_PANEL_PROFILE:-Goji XHTTP-TLS}» → вставьте JSON → Save."
  echo "----------------8<---------------- начало ----------------8<----------------"
  cat "$out"
  echo "----------------8<----------------  конец  ----------------8<----------------"
  echo "Дальше: Nodes → ваша нода → Config Profile → этот профиль, inbound XHTTP-TLS;"
  echo "Hosts → Create → inbound XHTTP-TLS, адрес $GOJI_DOMAIN, порт 443, Network xhttp,"
  echo "path $GOJI_XPATH, mode auto, Security tls, SNI $GOJI_DOMAIN, ALPN h2, Fingerprint firefox."
  echo "Показать снова: goji-node profile"
}

# Развёртывание сайта-заглушки из каталога шаблона. Использует GOJI_WEBROOT.
goji_deploy_decoy() { # goji_deploy_decoy <name> <templates dir>
  local name=$1 src=$2/$1
  [[ -d $src ]] || { echo "Нет шаблона «$name»" >&2; return 1; }
  mkdir -p "$GOJI_WEBROOT"
  find "$GOJI_WEBROOT" -mindepth 1 -delete
  cp -a "$src/." "$GOJI_WEBROOT/"
  [[ -f "$GOJI_WEBROOT/LICENSE" ]] && mv "$GOJI_WEBROOT/LICENSE" "$GOJI_WEBROOT/LICENSE.txt"
  if [[ ! -f "$GOJI_WEBROOT/404.html" ]]; then
    cat > "$GOJI_WEBROOT/404.html" <<'EOF404'
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>404 Not Found</title>
<style>body{font-family:system-ui,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0;color:#333}h1{font-weight:500}</style></head>
<body><div><h1>404 Not Found</h1><p><a href="/">Home</a></p></div></body></html>
EOF404
  fi
  [[ -f "$GOJI_WEBROOT/robots.txt" ]] || printf 'User-agent: *\nDisallow: /api/\n' > "$GOJI_WEBROOT/robots.txt"
  echo "$name" > "$GOJI_WEBROOT/.template"
  chown -R www-data:www-data "$GOJI_WEBROOT" 2>/dev/null || true
}

# Список шаблонов с номерами: печатает «имя<TAB>описание».
goji_tpl_list() { # goji_tpl_list <templates dir>
  local d n
  for d in "$1"/*/; do n=${d%/}; n=${n##*/}; printf '%s\t%s\n' "$n" "$(goji_tpl_desc "$n")"; done
}

# Меню выбора заглушки; печатает выбранное имя (random — случайная). Работает с терминала.
goji_tpl_choose() { # goji_tpl_choose <templates dir> [current]
  local dir=$1 cur=${2:-} names=() n i=0 pick
  while IFS=$'\t' read -r n _; do names+=("$n"); done < <(goji_tpl_list "$dir")
  {
    echo
    echo "Выберите сайт-заглушку (его видят все, кто открывает https://домен/):"
    echo "   0) случайная"
    for n in "${names[@]}"; do
      i=$((i + 1))
      printf '  %2d) %-11s %s%s\n' "$i" "$n" "$(goji_tpl_desc "$n")" "$([[ $n == "$cur" ]] && echo '  [сейчас]')"
    done
  } >&2
  while :; do
    read -r -p "Номер [0]: " pick </dev/tty || { echo random; return 0; }
    pick=${pick:-0}
    if [[ $pick == 0 ]]; then echo random; return 0; fi
    if [[ $pick =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#names[@]} )); then echo "${names[pick-1]}"; return 0; fi
    echo "Введите число от 0 до ${#names[@]}." >&2
  done
}

# Смена заглушки: goji-node decoy [имя]
goji_decoy() {
  gjc_load || return 1
  local dir=$GOJI_SHARE/templates name=${1:-} code
  [[ -d $dir ]] || { echo "Шаблоны не найдены в $dir — запустите install.sh --resume." >&2; return 1; }
  [[ -n $name ]] || name=$(goji_tpl_choose "$dir" "$(cat "$GOJI_WEBROOT/.template" 2>/dev/null)")
  if [[ $name == random ]]; then name=$(ls "$dir" | shuf -n 1); fi
  goji_deploy_decoy "$name" "$dir" || return 1
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 --resolve "$GOJI_DOMAIN:443:127.0.0.1" "https://$GOJI_DOMAIN/" 2>/dev/null || true)
  echo "Заглушка «$name» установлена. Проверка https://$GOJI_DOMAIN/ → HTTP ${code:-нет ответа}."
}

goji_menu() {
  local c
  while :; do
    cat <<'MENU'

================ Goji node — меню ================
  1) Полная проверка настроек
  2) Сайт, сертификат и nginx
  3) Нода Remnawave и Xray
  4) Система: BBR, ZRAM, обновления
  5) Защита: UFW, Fail2ban, SSH, ping, Traffic Control
  6) Открытые порты и правила UFW
  7) Профиль для Remnawave (готовый JSON)
  8) Сменить сайт-заглушку
  9) Проверить автопродление сертификата (certbot --dry-run)
  0) Выход
MENU
    read -r -p "Пункт: " c || return 0
    case "$c" in
      1) goji_check all || true ;;
      2) goji_check web || true ;;
      3) goji_check node || true ;;
      4) goji_check system || true ;;
      5) goji_check security || true ;;
      6) goji_ports ;;
      7) goji_show_profile ;;
      8) goji_decoy ;;
      9) certbot renew --dry-run ;;
      0|q|"") return 0 ;;
      *) echo "Нет такого пункта." ;;
    esac
  done
}

goji_main() {
  case "${1:-menu}" in
    menu)         goji_menu ;;
    check)        shift; goji_check "$@" ;;
    ports)        goji_ports ;;
    profile)      goji_show_profile ;;
    decoy)        shift; goji_decoy "$@" ;;
    -h|--help|help) echo "goji-node [menu] | check [web|node|system|security|all] | ports | profile | decoy [имя|random]" ;;
    *)            echo "Неизвестная команда: $1 (goji-node --help)" >&2; return 1 ;;
  esac
}
# end of shared block

# ---------------------------------------------------------------- resume / saved configuration
for a in "$@"; do
  case "$a" in
    --version) echo "goji-node-setup $VERSION"; exit 0 ;;
    --resume)  RESUME=1 ;;
    --check)   CHECK=1 ;;
  esac
done
if [[ $RESUME -eq 1 ]]; then
  [[ -r $CONF_FILE ]] || die "--resume: нет сохранённой установки ($CONF_FILE); сначала запустите install.sh обычным образом"
  # shellcheck disable=SC1090
  . "$CONF_FILE"
  DOMAIN=${GOJI_DOMAIN:-}; EMAIL=${GOJI_EMAIL:-}; XRAY_PORT=${GOJI_XRAY_PORT:-$XRAY_PORT}; XPATH=${GOJI_XPATH:-$XPATH}
  NODE_PORT=${GOJI_NODE_PORT:-}; PANEL_IP=${GOJI_PANEL_IP:-}; SSH_PORT=${GOJI_SSH_PORT:-}
  SKIP_NODE=${GOJI_SKIP_NODE:-0}; HARDEN=${GOJI_HARDEN:-1}; ICMP_DROP=${GOJI_ICMP_DROP:-0}; GUARD_MODE=${GOJI_GUARD:-0}; UPGRADE_MODE=${GOJI_UPGRADE:-0}
  PANEL_URL=${GOJI_PANEL_URL:-}; PANEL_NODE=${GOJI_PANEL_NODE:-}; PANEL_PROFILE=${GOJI_PANEL_PROFILE:-$PANEL_PROFILE}
  PANEL_HOST=${GOJI_PANEL_HOST:-}; PANEL_OVERWRITE=${GOJI_PANEL_OVERWRITE:-0}; read -ra PANEL_SQUADS <<< "${GOJI_PANEL_SQUADS:-}"
  [[ -z $PANEL_URL ]] || PANEL_MODE=1
  read -ra ADMIN_IPS <<< "${GOJI_ADMIN_IPS:-}"
  read -ra EXTRA_PORTS <<< "${GOJI_EXTRA_PORTS:-}"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --email)     EMAIL="$2"; shift 2 ;;
    --xray-port) XRAY_PORT="$2"; shift 2 ;;
    --path)      XPATH="$2"; shift 2 ;;
    --wait)      WAIT="$2"; shift 2 ;;
    --secret-key) SECRET_KEY="$2"; shift 2 ;;
    --node-port) NODE_PORT="$2"; shift 2 ;;
    --panel-ip)  PANEL_IP="$2"; shift 2 ;;
    --skip-node) SKIP_NODE=1; shift ;;
    --template)  TEMPLATE="$2"; shift 2 ;;
    --skip-hardening) HARDEN=0; shift ;;
    --icmp-drop) ICMP_DROP=1; shift ;;
    --ssh-port)  SSH_PORT="$2"; shift 2 ;;
    --allow-port) EXTRA_PORTS+=("$2"); shift 2 ;;
    --admin-ip)  ADMIN_IPS+=("$2"); shift 2 ;;
    --traffic-control)    GUARD_MODE=1; shift ;;
    --no-traffic-control) GUARD_MODE=0; shift ;;
    --upgrade-os)    UPGRADE_MODE=1; shift ;;
    --panel-url)     PANEL_URL="$2"; PANEL_MODE=1; shift 2 ;;
    --panel-token)   PANEL_TOKEN="$2"; warn "--panel-token виден в списке процессов; лучше переменная GOJI_PANEL_TOKEN или скрытый ввод"; shift 2 ;;
    --panel-node)    PANEL_NODE="$2"; shift 2 ;;
    --panel-profile) PANEL_PROFILE="$2"; shift 2 ;;
    --panel-host)    PANEL_HOST="$2"; shift 2 ;;
    --panel-squad)   PANEL_SQUADS+=("$2"); shift 2 ;;
    --panel-overwrite-profile) PANEL_OVERWRITE=1; shift ;;
    --no-panel)      PANEL_MODE=0; PANEL_URL=""; shift ;;
    --no-upgrade-os) UPGRADE_MODE=0; shift ;;
    --resume|--check) shift ;;
    -h|--help)   sed -n '2,24p' "$0"; exit 0 ;;
    -*)          die "неизвестный параметр: $1" ;;
    *)           DOMAIN="$1"; shift ;;
  esac
done

[[ $EUID -eq 0 ]] || die "запустите от root"
if [[ $CHECK -eq 1 ]]; then rc=0; goji_check || rc=$?; exit $rc; fi
command -v apt-get >/dev/null || die "поддерживаются только Debian/Ubuntu (apt)"
[[ "$XPATH" == /*/ ]] || die "--path должен начинаться и заканчиваться на '/'"

# ---------------------------------------------------------------- lock, signals, preflight
exec 9>/run/goji-node-setup.lock
flock -n 9 || die "другой goji-node-setup уже запущен"
trap 'exit 130' INT
trap 'exit 143' TERM

preflight() {
  [[ -d /run/systemd/system ]] || die "нужен systemd"
  local id="" ver=""
  if [[ -r /etc/os-release ]]; then id=$(. /etc/os-release; echo "${ID:-}"); ver=$(. /etc/os-release; echo "${VERSION_ID:-}"); fi
  case "$id:$ver" in
    debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) ;;
    *) warn "ОС '$id $ver' не проверялась (поддерживаются Debian 12/13, Ubuntu 22.04/24.04) — продолжаю" ;;
  esac
  case "$(uname -m)" in
    x86_64|aarch64) ;;
    *) warn "архитектура $(uname -m) не проверялась" ;;
  esac
  local free_kb
  free_kb=$(df -Pk / | awk 'NR==2{print $4}')
  [[ ${free_kb:-0} -ge 1048576 ]] || die "на / свободно меньше 1 ГиБ — освободите место"
  if command -v ss >/dev/null && ss -Hltnp 'sport = :80' | grep -q . && ! ss -Hltnp 'sport = :80' | grep -q nginx; then
    die "порт 80 занят другим сервисом ($(ss -Hltnp 'sport = :80' | head -1 | grep -o 'users:.*' | head -1)); он нужен certbot и редиректу"
  fi
  command -v sshd >/dev/null || warn "sshd не найден — усиление SSH будет пропущено"
  [[ -n "${SSH_CONNECTION:-}" ]] || warn "это не SSH-сессия — держите консоль открытой до конца установки"
}
preflight

WEBROOT=$GOJI_WEBROOT
ACME=/var/www/acme
CONF=/etc/nginx/conf.d/xhttp-tls.conf
ACME_CONF=/etc/nginx/conf.d/xhttp-acme.conf
LIVE=/etc/letsencrypt/live/$DOMAIN

# ---------------------------------------------------------------- questions
# Works with "curl ... | bash" too: prompts read from the terminal, not stdin.
ask() { # ask <var> <prompt> [default] [secret]
  local __v="$1" __p="$2" __d="${3:-}" __s="${4:-}" __a=""
  [[ -r /dev/tty ]] || die "нет терминала для вопросов; передайте «$__p» параметрами"
  if [[ -n "$__d" ]]; then __p="$__p [$__d]"; fi
  if [[ -n "$__s" ]]; then
    read -r -s -p "$__p: " __a </dev/tty; echo >/dev/tty
  else
    read -r -p "$__p: " __a </dev/tty
  fi
  printf -v "$__v" '%s' "${__a:-$__d}"
}

if [[ -z "$DOMAIN" ]]; then
  ask DOMAIN "Домен этого сервера (A-запись должна указывать сюда), например node.example.com" ""
fi
DOMAIN="${DOMAIN,,}"
[[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || die "некорректный домен: '$DOMAIN'"
LIVE=/etc/letsencrypt/live/$DOMAIN

OLD_KEY=""; OLD_PORT=""
if [[ -f "$NODE_DIR/docker-compose.yml" ]]; then
  OLD_KEY=$(sed -nE 's/.*SECRET_KEY[=:][[:space:]]*["'"'"']?([^"'"'"']+)["'"'"']?[[:space:]]*$/\1/p' "$NODE_DIR/docker-compose.yml" | head -1)
  OLD_PORT=$(sed -nE 's/.*(NODE_PORT|APP_PORT)[=:][[:space:]]*["'"'"']?([0-9]+).*/\2/p' "$NODE_DIR/docker-compose.yml" | head -1)
fi

if [[ $SKIP_NODE -eq 0 ]]; then
  if [[ -z "$SECRET_KEY" && $RESUME -eq 1 && -n "$OLD_KEY" ]]; then SECRET_KEY="$OLD_KEY"; fi
  if [[ -z "$SECRET_KEY" ]]; then
    echo "Remnawave Node будет переустановлена в $NODE_DIR."
    echo "SECRET_KEY: Панель → Nodes → (эта нода) → скопируйте ключ из docker-compose."
    if [[ -n "$OLD_KEY" ]]; then
      ask SECRET_KEY "SECRET_KEY (Enter = оставить текущий)" "" secret
      SECRET_KEY="${SECRET_KEY:-$OLD_KEY}"
    else
      ask SECRET_KEY "SECRET_KEY" "" secret
    fi
  fi
  [[ -n "$SECRET_KEY" ]] || die "SECRET_KEY пустой"
  [[ -n "$NODE_PORT" ]] || ask NODE_PORT "NODE_PORT (порт API ноды для панели)" "${OLD_PORT:-2222}"
  [[ "$NODE_PORT" =~ ^[0-9]+$ ]] || die "NODE_PORT должен быть числом"
  [[ -n "$PANEL_IP" || $RESUME -eq 1 ]] || ask PANEL_IP "IP панели, которому открыть NODE_PORT (Enter = без правила файрвола)" ""
  if [[ -z "$EMAIL" && $RESUME -eq 0 ]]; then ask EMAIL "E-mail для Let's Encrypt (Enter = без e-mail)" ""; fi
fi

# Traffic Control (blocklists of scanner networks) is opt-in.
if [[ $HARDEN -eq 1 ]]; then
  if [[ -z "$GUARD_MODE" ]]; then
    GUARD_MODE=0
    if [[ -r /dev/tty ]]; then
      read -r -p "Установить Traffic Control (ежедневно обновляемые списки сетей сканеров; администратор, панель и SSH исключены)? [y/N]: " __g </dev/tty || true
      [[ "${__g:-}" =~ ^[yYдД] ]] && GUARD_MODE=1
    fi
  fi
  GUARD_ON=$GUARD_MODE
fi

# Remnawave panel: profile, node assignment and host through the panel API (opt-in).
if [[ "$PANEL_MODE" != 0 ]]; then
  if [[ -z "$PANEL_URL" && "$PANEL_MODE" != 1 && $RESUME -eq 0 && -r /dev/tty ]]; then
    read -r -p "Настроить панель Remnawave автоматически через API (профиль, нода, хост)? [y/N]: " __p </dev/tty || true
    [[ "${__p:-}" =~ ^[yYдД] ]] && PANEL_MODE=1
  fi
  if [[ "$PANEL_MODE" == 1 ]]; then
    [[ -n "$PANEL_URL" ]] || ask PANEL_URL "Адрес панели, например https://panel.example.com" ""
    PANEL_URL="${PANEL_URL%/}"
    [[ "$PANEL_URL" =~ ^https?://[^[:space:]]+$ ]] || die "некорректный адрес панели: '$PANEL_URL'"
    if [[ -z "$PANEL_TOKEN" && $RESUME -eq 0 ]]; then
      ask PANEL_TOKEN "API-токен панели (ввод скрыт; создаётся в панели: API tokens)" "" secret
    fi
    [[ -n "$PANEL_TOKEN" ]] || warn "нет API-токена панели — шаг панели будет пропущен (задайте GOJI_PANEL_TOKEN и запустите с --resume)"
  fi
fi

# Installing updates of the current OS release (apt upgrade, not a release upgrade).
if [[ -z "$UPGRADE_MODE" ]]; then
  UPGRADE_MODE=0
  if [[ -r /dev/tty ]]; then
    read -r -p "Сначала установить доступные обновления этой версии ОС (apt upgrade)? [Y/n]: " __u </dev/tty || true
    [[ "${__u:-y}" =~ ^[yYдД] ]] && UPGRADE_MODE=1
  fi
fi
UPGRADE_ON=$UPGRADE_MODE

save_conf() {
  mkdir -p /etc/goji-node
  {
    echo "# Managed by goji-node-setup $VERSION"
    printf 'GOJI_VERSION=%q\n' "$VERSION"
    printf 'GOJI_DOMAIN=%q\n' "$DOMAIN"
    printf 'GOJI_EMAIL=%q\n' "$EMAIL"
    printf 'GOJI_XRAY_PORT=%q\n' "$XRAY_PORT"
    printf 'GOJI_XPATH=%q\n' "$XPATH"
    printf 'GOJI_NODE_PORT=%q\n' "$NODE_PORT"
    printf 'GOJI_PANEL_IP=%q\n' "$PANEL_IP"
    printf 'GOJI_SSH_PORT=%q\n' "$SSH_PORT"
    printf 'GOJI_SKIP_NODE=%q\n' "$SKIP_NODE"
    printf 'GOJI_HARDEN=%q\n' "$HARDEN"
    printf 'GOJI_ICMP_DROP=%q\n' "$ICMP_DROP"
    printf 'GOJI_GUARD=%q\n' "$GUARD_ON"
    printf 'GOJI_UPGRADE=%q\n' "$UPGRADE_ON"
    printf 'GOJI_PANEL_URL=%q\n' "$PANEL_URL"
    printf 'GOJI_PANEL_NODE=%q\n' "$PANEL_NODE"
    printf 'GOJI_PANEL_PROFILE=%q\n' "$PANEL_PROFILE"
    printf 'GOJI_PANEL_HOST=%q\n' "$PANEL_HOST"
    printf 'GOJI_PANEL_OVERWRITE=%q\n' "$PANEL_OVERWRITE"
    printf 'GOJI_PANEL_SQUADS=%q\n' "${PANEL_SQUADS[*]:-}"
    printf 'GOJI_ADMIN_IPS=%q\n' "${ADMIN_IPS[*]:-}"
    printf 'GOJI_EXTRA_PORTS=%q\n' "${EXTRA_PORTS[*]:-}"
  } > "$CONF_FILE.tmp"
  chmod 600 "$CONF_FILE.tmp"
  mv -f "$CONF_FILE.tmp" "$CONF_FILE"
}
save_conf

# --resume: do not reinstall a node that is already running with the saved settings
if [[ $RESUME -eq 1 && $SKIP_NODE -eq 0 ]] && command -v docker >/dev/null \
   && [[ "$(docker inspect -f '{{.State.Running}}' remnanode 2>/dev/null)" == true ]]; then
  info "resume: Remnawave Node уже работает — не переустанавливаю"
  SKIP_NODE=1
fi

# ---------------------------------------------------------------- packages
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

# Updates of the installed release only (no do-release-upgrade). The plan is simulated first:
# if it would REMOVE any package nothing is upgraded. Config files you changed are kept
# (--force-confold) and needrestart is told not to restart services behind your back.
os_upgrade() {
  local plan removed upgraded
  plan=$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null) || { warn "apt не смог смоделировать обновление — пропущено"; return 0; }
  removed=$(grep -c '^Remv ' <<< "$plan" || true)
  upgraded=$(grep -c '^Inst ' <<< "$plan" || true)
  if [[ ${removed:-0} -gt 0 ]]; then
    warn "обновление удалило бы пакеты ($removed) — не обновляю; посмотрите: apt-get -s upgrade"
    return 0
  fi
  if [[ ${upgraded:-0} -eq 0 ]]; then ok "система уже обновлена"; return 0; fi
  info "Устанавливаю обновления пакетов этой версии ОС: $upgraded"
  if NEEDRESTART_SUSPEND=1 apt-get -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade >/dev/null; then
    ok "пакеты системы обновлены ($upgraded)"
    [[ -f /var/run/reboot-required ]] && warn "для завершения обновлений (ядро/libc) нужна перезагрузка — перезагрузитесь, когда удобно"
  else
    warn "apt upgrade завершился ошибкой — смотрите: apt-get -f install; продолжаю без него"
  fi
  return 0
}
if [[ $UPGRADE_ON -eq 1 ]]; then os_upgrade; else info "Обновление пакетов ОС пропущено (параметр --upgrade-os)"; fi

info "Устанавливаю nginx и certbot"
# nftables is installed before any firewall rule exists: its postinst may load the packaged
# /etc/nftables.conf ("flush ruleset"), which would wipe ufw/docker rules loaded earlier.
# We only need the nft binary, so a freshly installed nftables.service is disabled.
pkgs=(nginx certbot curl ca-certificates iproute2)
NFT_PREINSTALLED=0; command -v nft >/dev/null && NFT_PREINSTALLED=1
[[ $HARDEN -eq 1 ]] && pkgs+=(nftables)
pkgs+=(python3-minimal)      # профиль Remnawave (goji-node profile), goji-panel, goji-guard
apt-get install -y -qq "${pkgs[@]}" >/dev/null
if [[ $HARDEN -eq 1 && $NFT_PREINSTALLED -eq 0 ]]; then
  systemctl disable nftables.service >/dev/null 2>&1 || true
fi
ok "nginx $(nginx -v 2>&1 | sed 's#.*/##')"

# ---------------------------------------------------------------- DNS sanity
MY_IP=$(curl -4 -fsS --max-time 5 https://api.ipify.org || true)
DNS_IP=$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}' || true)
if [[ -n "$MY_IP" && -n "$DNS_IP" && "$MY_IP" != "$DNS_IP" ]]; then
  warn "$DOMAIN указывает на $DNS_IP, а этот VPS — $MY_IP: выпуск сертификата не удастся"
fi

# ---------------------------------------------------------------- decoy site
# Шаблоны распаковываются и остаются в /usr/share/goji-node/templates: заглушку можно
# сменить позже командой `goji-node decoy` (или пунктом меню) без повторной установки.
TPL_DIR=$(mktemp -d)
trap 'rm -rf "$TPL_DIR"' EXIT
echo "__TEMPLATES_B64__" | base64 -d | tar -xz -C "$TPL_DIR"
TEMPLATES=$(ls "$TPL_DIR")
rm -rf "$GOJI_SHARE/templates"; mkdir -p "$GOJI_SHARE/templates"
cp -a "$TPL_DIR/." "$GOJI_SHARE/templates/"
if [[ -z "$TEMPLATE" && -f "$WEBROOT/.template" ]]; then
  TEMPLATE=$(cat "$WEBROOT/.template")          # сайт не меняется при повторных запусках
  [[ -d "$TPL_DIR/$TEMPLATE" ]] || { warn "сохранённая заглушка «$TEMPLATE» больше не существует — выбираем заново"; TEMPLATE=""; }
  [[ -z "$TEMPLATE" ]] || info "Сайт-заглушка «$TEMPLATE» уже установлена (сменить: goji-node decoy)"
fi
if [[ -z "$TEMPLATE" && -r /dev/tty ]]; then
  TEMPLATE=$(goji_tpl_choose "$TPL_DIR" "")
fi
if [[ -z "$TEMPLATE" || "$TEMPLATE" == random ]]; then
  TEMPLATE=$(echo "$TEMPLATES" | shuf -n 1)
fi
[[ "$TEMPLATE" =~ ^[a-z0-9-]+$ && -d "$TPL_DIR/$TEMPLATE" ]] || die "неизвестная заглушка «$TEMPLATE» (доступны: $(echo $TEMPLATES))"
info "Устанавливаю сайт-заглушку «$TEMPLATE» в $WEBROOT"
mkdir -p "$ACME"
goji_deploy_decoy "$TEMPLATE" "$TPL_DIR"
chown -R www-data:www-data "$ACME" 2>/dev/null || true

# ---------------------------------------------------------------- nginx :80
rm -f /etc/nginx/sites-enabled/default
cat > "$ACME_CONF" <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $DOMAIN;
    server_tokens off;

    location /.well-known/acme-challenge/ {
        root $ACME;
    }

    location / {
        return 301 https://$DOMAIN\$request_uri;
    }
}
EOF
rm -f "$CONF"
nginx -t -q
# A previous setup may have masked nginx ("Unit file ... is masked"): unmask it,
# otherwise enable/start fail. Only /dev/null symlinks and empty override files are removed.
unit=/etc/systemd/system/nginx.service
if [[ -L $unit && $(readlink "$unit") == /dev/null ]] || [[ -f $unit && ! -s $unit ]]; then
  warn "nginx.service был замаскирован — снимаю маскировку"
  rm -f "$unit"
fi
systemctl unmask nginx.service >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl enable --now nginx >/dev/null
systemctl reload nginx

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
  ok "ufw: порты 80/tcp и 443/tcp открыты"
fi

# ---------------------------------------------------------------- certificate
RENEW_CONF=/etc/letsencrypt/renewal/$DOMAIN.conf
ARCHIVE=/etc/letsencrypt/archive/$DOMAIN
need_cert=1
if [[ -f "$LIVE/fullchain.pem" && -f "$RENEW_CONF" ]]; then
  if grep -q "authenticator = webroot" "$RENEW_CONF"; then
    need_cert=0
    ok "Сертификат для $DOMAIN уже есть и продлевается через webroot"
  else
    info "Текущий сертификат продлевается другим способом — выпускаю заново через webroot"
  fi
fi
if [[ $need_cert -eq 1 ]]; then
  # live/ or archive/ left without a renewal config (copied by hand, another
  # ACME client, broken lineage) makes certbot refuse: move them aside.
  if [[ ! -f "$RENEW_CONF" ]] && [[ -e "$LIVE" || -e "$ARCHIVE" ]]; then
    bak=/root/letsencrypt-backup-$DOMAIN-$(date +%Y%m%d-%H%M%S)
    mkdir -p "$bak"
    [[ -e "$LIVE" ]] && mv "$LIVE" "$bak/live"
    [[ -e "$ARCHIVE" ]] && mv "$ARCHIVE" "$bak/archive"
    warn "Посторонние файлы сертификата для $DOMAIN перенесены в $bak"
  fi
  mail_args=(--register-unsafely-without-email)
  [[ -n "$EMAIL" ]] && mail_args=(-m "$EMAIL")
  certbot certonly --webroot -w "$ACME" -d "$DOMAIN" --cert-name "$DOMAIN" \
    --agree-tos --non-interactive --force-renewal "${mail_args[@]}" >/dev/null
  ok "Сертификат для $DOMAIN выпущен"
fi
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/sh
systemctl reload nginx
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
if certbot renew --cert-name "$DOMAIN" --dry-run >/dev/null 2>&1; then
  ok "certbot renew --dry-run прошёл — автопродление работает"
else
  warn "certbot renew --dry-run не прошёл — проверьте порт 80 и выполните: certbot renew --dry-run"
fi

# ---------------------------------------------------------------- remnawave node
if [[ $SKIP_NODE -eq 0 ]]; then
  if ! command -v docker >/dev/null; then
    info "Устанавливаю Docker"
    curl -fsSL https://get.docker.com | sh >/dev/null
  fi
  docker compose version >/dev/null 2>&1 || die "нет плагина docker compose"

  mkdir -p "$NODE_DIR"
  if [[ -f "$NODE_DIR/docker-compose.yml" ]]; then
    bak="$NODE_DIR/docker-compose.yml.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$NODE_DIR/docker-compose.yml" "$bak"
    info "Старый compose сохранён в $bak"
    (cd "$NODE_DIR" && docker compose down --remove-orphans) || true
  fi
  # remove a leftover container with the same name started outside compose
  docker rm -f remnanode >/dev/null 2>&1 || true

  info "Переустанавливаю Remnawave Node (порт $NODE_PORT)"
  KEY_ESC=${SECRET_KEY//\'/\'\'}
  cat > "$NODE_DIR/docker-compose.yml" <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    restart: always
    network_mode: host
    environment:
      NODE_PORT: "$NODE_PORT"
      SECRET_KEY: '$KEY_ESC'
    volumes:
      - /etc/letsencrypt:/etc/letsencrypt:ro
EOF
  chmod 600 "$NODE_DIR/docker-compose.yml"
  (cd "$NODE_DIR" && docker compose pull -q) >/dev/null
  # Pin the pulled image by digest so a later "up" cannot silently change versions.
  NODE_IMAGE=$(cd "$NODE_DIR" && docker compose config --images | head -1)
  NODE_DIGEST=$(docker image inspect "$NODE_IMAGE" --format '{{index .RepoDigests 0}}' 2>/dev/null || true)
  if [[ $NODE_DIGEST =~ ^[^[:space:]@]+@sha256:[[:xdigit:]]{64}$ ]]; then
    sed -i "s|image: remnawave/node:latest|image: $NODE_DIGEST|" "$NODE_DIR/docker-compose.yml"
    ok "Образ ноды закреплён: $NODE_DIGEST"
  else
    warn "Не удалось получить digest образа — в compose остаётся remnawave/node:latest"
  fi
  (cd "$NODE_DIR" && docker compose up -d) >/dev/null

  for ((i = 0; i < 30; i++)); do
    ss -Hltn "sport = :$NODE_PORT" | grep -q . && break
    sleep 2
  done
  if ss -Hltn "sport = :$NODE_PORT" | grep -q .; then
    ok "Remnawave Node запущена, порт :$NODE_PORT"
  else
    warn "Нода не слушает :$NODE_PORT — смотрите: docker compose -f $NODE_DIR/docker-compose.yml logs -t"
  fi

  if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    if [[ -n "$PANEL_IP" ]]; then
      ufw allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp >/dev/null
      ok "ufw: $NODE_PORT/tcp открыт только для $PANEL_IP"
    else
      warn "ufw включён, IP панели не задан — убедитесь, что панель достучится до :$NODE_PORT"
    fi
  elif [[ -n "$PANEL_IP" ]]; then
    warn "ufw не включён — ограничьте :$NODE_PORT адресом $PANEL_IP в вашем файрволе вручную"
  fi
else
  if command -v docker >/dev/null; then
    for c in $(docker ps --format '{{.Names}}' | grep -i remna || true); do
      mode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$c")
      [[ "$mode" == "host" ]] || warn "контейнер $c использует сеть '$mode' — nginx не достанет до 127.0.0.1:$XRAY_PORT; задайте network_mode: host"
    done
  fi
fi

if ! ss -Hltn "sport = :1080" | grep -q .; then
  warn "На :1080 никто не слушает — Psiphon не работает; Gemini пойдёт напрямую (профиль переключится сам)"
fi

# ---------------------------------------------------------------- hardening & tuning
# UFW, Fail2ban, ZRAM, BBR + fq, tc (fq on the uplink), sysctl tuning and
# rate-limiting of incoming ICMP echo. Every step is best-effort: a failure prints
# a warning and never aborts the node install. Skip with --skip-hardening.
harden_system() {
  local in_container=0
  systemd-detect-virt --container --quiet 2>/dev/null && in_container=1

  info "Усиление защиты и тюнинг сервера"
  if ! apt-get install -y -qq ufw fail2ban >/dev/null; then
    warn "не удалось установить ufw/fail2ban — усиление защиты пропущено"
    return 0
  fi
  apt-get install -y -qq python3-systemd >/dev/null 2>&1 || true

  # ---- SSH port(s): detected before any firewall rule so we never lock ourselves out
  local ssh_ports=()
  if [[ -n "$SSH_PORT" ]]; then
    ssh_ports=("$SSH_PORT")
  else
    mapfile -t ssh_ports < <(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -un)
    if [[ ${#ssh_ports[@]} -eq 0 ]]; then
      mapfile -t ssh_ports < <(ss -Hltnp 2>/dev/null | awk '/sshd/{n=split($4,a,":"); print a[n]}' | sort -un)
    fi
    if [[ ${#ssh_ports[@]} -eq 0 ]]; then
      warn "не удалось определить порт SSH — считаю 22 (укажите --ssh-port)"
      ssh_ports=(22)
    fi
  fi

  SSH_PORTS_DETECTED="${ssh_ports[*]}"

  # ---- sysctl: BBR + fq, socket buffers, backlog, basic anti-spoofing
  local SYSCTL=/etc/sysctl.d/99-goji-tuning.conf bbr_ok=0
  modprobe tcp_bbr 2>/dev/null || true
  modprobe nf_conntrack 2>/dev/null || true
  if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    bbr_ok=1
    echo tcp_bbr > /etc/modules-load.d/goji-bbr.conf
  else
    warn "BBR недоступен в этом ядре — оставляю текущий алгоритм"
  fi
  {
    echo "# Managed by goji-node-setup"
    if [[ $bbr_ok -eq 1 ]]; then
      echo "net.core.default_qdisc = fq"
      echo "net.ipv4.tcp_congestion_control = bbr"
    fi
    cat <<'EOF'
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.ip_local_port_range = 10240 65535
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_syncookies = 1
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
fs.file-max = 1048576
vm.swappiness = 100
vm.page-cluster = 0
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
EOF
    if [[ -e /proc/sys/net/netfilter/nf_conntrack_max ]]; then
      echo "net.netfilter.nf_conntrack_max = 262144"
      echo nf_conntrack > /etc/modules-load.d/goji-conntrack.conf
    fi
  } > "$SYSCTL"
  if sysctl -q -p "$SYSCTL" >/dev/null 2>&1; then
    ok "тюнинг sysctl применён ($(sysctl -n net.ipv4.tcp_congestion_control)/$(sysctl -n net.core.default_qdisc))"
  else
    warn "часть параметров sysctl отклонена (ограничения контейнера/VPS) — остальные применены; смотрите: sysctl -p $SYSCTL"
  fi

  # ---- Traffic Control: fq on the uplink (default_qdisc only covers new interfaces)
  if [[ $in_container -eq 1 ]]; then
    warn "обнаружен контейнер — tc и ZRAM пропущены"
  else
    cat > /usr/local/sbin/goji-tc.sh <<'EOF'
#!/bin/sh
# fq on the default-route interface; keeps an existing fq (or mq with fq children).
IF=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
[ -n "$IF" ] || exit 0
tc qdisc show dev "$IF" | grep -q '^qdisc fq ' && exit 0
tc qdisc replace dev "$IF" root fq 2>/dev/null || tc qdisc replace dev "$IF" root fq_codel 2>/dev/null || true
EOF
    chmod 755 /usr/local/sbin/goji-tc.sh
    cat > /etc/systemd/system/goji-tc.service <<'EOF'
[Unit]
Description=Goji traffic control (fq on uplink)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/goji-tc.sh

[Install]
WantedBy=multi-user.target
EOF

    # ---- ZRAM swap (size = PERCENT of RAM, edit /etc/default/goji-zram)
    cat > /usr/local/sbin/goji-zram.sh <<'EOF'
#!/bin/sh
set -eu
[ -r /etc/default/goji-zram ] && . /etc/default/goji-zram
PERCENT=${PERCENT:-50}
ALGO=${ALGO:-zstd}
case "${1:-start}" in
  start)
    swapon --noheadings --show=NAME | grep -q '^/dev/zram' && exit 0
    modprobe zram
    mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    size=$((mem_kb * PERCENT / 100 * 1024))
    dev=$(zramctl --find --algorithm "$ALGO" --size "$size" 2>/dev/null) \
      || dev=$(zramctl --find --algorithm lz4 --size "$size" 2>/dev/null) \
      || dev=$(zramctl --find --size "$size")
    mkswap -q "$dev"
    swapon --priority 100 "$dev"
    ;;
  stop)
    for d in $(swapon --noheadings --show=NAME | grep '^/dev/zram' || true); do
      swapoff "$d"
      zramctl --reset "$d"
    done
    ;;
esac
EOF
    chmod 755 /usr/local/sbin/goji-zram.sh
    [[ -f /etc/default/goji-zram ]] || printf 'PERCENT=50\nALGO=zstd\n' > /etc/default/goji-zram
    cat > /etc/systemd/system/goji-zram.service <<'EOF'
[Unit]
Description=Goji ZRAM swap
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/goji-zram.sh start
ExecStop=/usr/local/sbin/goji-zram.sh stop

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    if systemctl enable --now goji-tc.service >/dev/null 2>&1; then
      ok "tc: fq на внешнем интерфейсе"
    else
      warn "goji-tc.service не запустился — смотрите: systemctl status goji-tc"
    fi
    if systemctl enable --now goji-zram.service >/dev/null 2>&1; then
      ok "swap на ZRAM включён ($(swapon --noheadings --show=NAME,SIZE | grep zram | tr -s ' ' | head -1))"
    else
      warn "ZRAM недоступен (ядро без zram?) — смотрите: systemctl status goji-zram"
    fi
  fi

  # ---- UFW (+ ICMP echo limiting). An already active ufw keeps its defaults.
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    warn "firewalld активен — правила ufw и ICMP пропущены"
  else
    local np="${NODE_PORT:-$OLD_PORT}" was_active=0 p proto port
    ufw status | grep -q "Status: active" && was_active=1
    if [[ $was_active -eq 0 ]]; then
      ufw default deny incoming >/dev/null
      ufw default allow outgoing >/dev/null
    fi
    for p in "${ssh_ports[@]}"; do ufw allow "$p/tcp" >/dev/null; done
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
    if [[ -n "$np" ]]; then
      if [[ -n "$PANEL_IP" ]]; then
        ufw allow from "$PANEL_IP" to any port "$np" proto tcp >/dev/null
      else
        warn "нет --panel-ip: $np/tcp открыт всем, чтобы панель достучалась до ноды; задайте --panel-ip, чтобы ограничить"
        ufw allow "$np/tcp" >/dev/null
      fi
    fi
    for p in "${EXTRA_PORTS[@]}"; do
      if [[ "$p" =~ ^[0-9]+(/(tcp|udp))?$ ]]; then
        ufw allow "$p" >/dev/null
      else
        warn "игнорирую некорректный --allow-port '$p' (используйте 8443 или 8443/tcp)"
      fi
    done
    # Public ports already served by the Xray core (other inbounds of the profile).
    while read -r proto port; do
      [[ -n "$port" ]] || continue
      ufw allow "$port/$proto" >/dev/null && info "ufw: оставляю $port/$proto (слушает xray)"
    done < <(ss -Hltunp 2>/dev/null | awk '$5 !~ /^(127\.|\[::1\]|::1)/ && /xray|rw-core/ {n=split($5,a,":"); print $1, a[n]}' | sort -u)

    if [[ $was_active -eq 1 ]]; then
      ufw reload >/dev/null || warn "ufw reload не удался — проверьте /etc/ufw/before.rules"
    else
      ufw --force enable >/dev/null || warn "не удалось включить ufw"
    fi
    if ufw status | grep -q "Status: active"; then
      ok "ufw включён (ssh: ${ssh_ports[*]}, 80, 443$([[ -n "$np" ]] && echo ", $np"))"
    fi
  fi

  # ---- Fail2ban (ssh + repeat offenders). Default ban action is used, it works next to ufw.
  local F2B=/etc/fail2ban/jail.d/goji.local ssh_csv
  ssh_csv=$(IFS=,; echo "${ssh_ports[*]}")
  cat > "$F2B" <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd
ignoreip = 127.0.0.1/8 ::1 $PANEL_IP
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 1w

[sshd]
enabled = true
port = $ssh_csv
maxretry = 4

[recidive]
enabled = true
backend = auto
bantime = 1w
findtime = 1d
maxretry = 3
EOF
  if fail2ban-client -t >/dev/null 2>&1; then
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban
    sleep 2
    if fail2ban-client ping >/dev/null 2>&1; then
      ok "fail2ban работает (jail: sshd, recidive)"
    else
      warn "fail2ban не запустился — смотрите: journalctl -u fail2ban"
    fi
  else
    rm -f "$F2B"
    warn "проверка конфигурации fail2ban не прошла — файл jail удалён; смотрите: fail2ban-client -t"
  fi
}

# ---------------------------------------------------------------- SSH hardening (with rollback)
# Only connection limits are tightened. Authentication methods, root login and
# AllowTcpForwarding keep their effective values; if sshd -T shows any change in
# them, or sshd rejects the file, the previous state is restored.
ssh_rollback() { # ssh_rollback <dropin> <had_dropin> <backup dir>
  local dropin="$1" had="$2" bk="$3" tmp
  if [[ $had -eq 1 ]]; then
    tmp=$(mktemp /etc/ssh/sshd_config.d/.goji-restore-XXXXXX)
    cp -p "$bk/sshd-dropin-before.conf" "$tmp" && mv -f "$tmp" "$dropin" || rm -f "$tmp"
  else
    rm -f "$dropin"
  fi
  sshd -t 2>/dev/null || true
  local u
  for u in ssh.service sshd.service; do
    systemctl is-active --quiet "$u" && systemctl try-reload-or-restart "$u" >/dev/null 2>&1 && break
  done
  warn "усиление SSH откатено — прежняя конфигурация восстановлена"
}

harden_ssh() {
  local dropin=/etc/ssh/sshd_config.d/00-goji-hardening.conf bk=/var/backups/goji-node had=0 tmp bad=0 kv k u
  command -v sshd >/dev/null || { warn "sshd не найден — усиление SSH пропущено"; return 0; }
  if ! grep -qsE '^[[:space:]]*Include[[:space:]]+.*sshd_config\.d' /etc/ssh/sshd_config; then
    warn "в sshd_config нет Include для sshd_config.d — усиление SSH пропущено"; return 0
  fi
  [[ ! -L $dropin ]] || { warn "$dropin — символическая ссылка; усиление SSH пропущено"; return 0; }
  mkdir -p /run/sshd "$bk" /etc/ssh/sshd_config.d; chmod 700 "$bk"
  sshd -t 2>/dev/null || { warn "текущая конфигурация sshd некорректна — усиление SSH пропущено"; return 0; }
  sshd -T > "$bk/sshd-before.txt" 2>/dev/null || { warn "sshd -T завершился ошибкой — усиление SSH пропущено"; return 0; }
  if [[ -f $dropin ]]; then cp -p "$dropin" "$bk/sshd-dropin-before.conf"; had=1; fi

  tmp=$(mktemp /etc/ssh/sshd_config.d/.goji-XXXXXX)
  cat > "$tmp" <<'CONF'
# Managed by goji-node-setup. Authentication methods, root login and
# AllowTcpForwarding are intentionally left untouched.
MaxAuthTries 4
LoginGraceTime 30
AllowAgentForwarding no
PermitTunnel no
X11Forwarding no
GatewayPorts no
CONF
  chmod 644 "$tmp"
  mv -f "$tmp" "$dropin"

  if ! sshd -t 2>/dev/null; then ssh_rollback "$dropin" "$had" "$bk"; return 0; fi
  sshd -T > "$bk/sshd-after.txt"
  for kv in "maxauthtries 4" "logingracetime 30" "allowagentforwarding no" "permittunnel no" "x11forwarding no" "gatewayports no"; do
    grep -qx "$kv" "$bk/sshd-after.txt" || { bad=1; warn "действующая настройка sshd отличается от '$kv' (приоритет у более раннего правила)"; }
  done
  for k in port allowtcpforwarding passwordauthentication pubkeyauthentication permitrootlogin kbdinteractiveauthentication authenticationmethods; do
    if [[ "$(grep -E "^$k " "$bk/sshd-before.txt" || true)" != "$(grep -E "^$k " "$bk/sshd-after.txt" || true)" ]]; then
      bad=1; warn "настройка SSH '$k' изменилась бы"
    fi
  done
  if [[ $bad -eq 1 ]]; then ssh_rollback "$dropin" "$had" "$bk"; return 0; fi

  for u in ssh.service sshd.service; do
    if systemctl is-active --quiet "$u"; then
      systemctl try-reload-or-restart "$u" >/dev/null 2>&1 || { ssh_rollback "$dropin" "$had" "$bk"; return 0; }
      break
    fi
  done
  ok "SSH: MaxAuthTries 4, LoginGraceTime 30, без agent/tunnel/X11-проброса (способ входа не менялся)"
}

# ---------------------------------------------------------------- ping protection (nftables)
# Early nftables layer (priority -300, loaded before network-pre.target): incoming
# ICMP echo-request is rate-limited (default) or dropped (--icmp-drop), ICMP
# timestamp-request is dropped. Outgoing ping, ICMP errors, PMTUD and IPv6
# neighbour discovery are not touched.
harden_ping() {
  local mode=limit
  [[ $ICMP_DROP -eq 1 ]] && mode=drop
  # older versions of this installer put the rules into ufw before*.rules: migrate
  local rf
  for rf in /etc/ufw/before.rules /etc/ufw/before6.rules; do
    [[ -f $rf ]] && grep -q -- '--comment goji-icmp' "$rf" && sed -i '/--comment goji-icmp/d' "$rf"
  done
  if ! command -v nft >/dev/null; then
    apt-get install -y -qq nftables >/dev/null 2>&1 || { warn "не удалось установить nftables — защита от ping пропущена"; return 0; }
  fi
  printf '# Managed by goji-node-setup\nMODE=%s\n' "$mode" > /etc/default/goji-two-way-ping
  cat > /usr/local/sbin/goji-two-way-ping.sh <<'SH'
#!/usr/bin/env bash
# goji-two-way-ping: early nftables layer against incoming ping / ICMP timestamp probes.
set -euo pipefail
TABLE=goji_privacy
MODE=limit
[[ -r /etc/default/goji-two-way-ping ]] && . /etc/default/goji-two-way-ping
rules() {
  echo "add table inet $TABLE"
  echo "delete table inet $TABLE"
  echo "table inet $TABLE {"
  echo "  chain input {"
  echo "    type filter hook input priority -300; policy accept;"
  echo '    iifname "lo" accept'
  echo "    icmp type timestamp-request drop"
  if [[ $MODE == limit ]]; then
    echo "    icmp type echo-request limit rate 5/second burst 10 packets accept"
    echo "    icmpv6 type echo-request limit rate 5/second burst 10 packets accept"
  fi
  echo "    icmp type echo-request drop"
  echo "    icmpv6 type echo-request drop"
  echo "  }"
  echo "}"
}
case "${1:-status}" in
  start|restart|reload) rules | nft -f - ;;
  stop)    nft delete table inet "$TABLE" 2>/dev/null || true ;;
  rules)   rules ;;
  status)  nft list table inet "$TABLE" ;;
  *) echo "usage: $0 start|stop|restart|status|rules" >&2; exit 2 ;;
esac
SH
  chmod 755 /usr/local/sbin/goji-two-way-ping.sh
  cat > /etc/systemd/system/goji-two-way-ping.service <<'UNIT'
[Unit]
Description=Goji: block incoming ping and ICMP timestamp probes
DefaultDependencies=no
After=local-fs.target systemd-modules-load.service nftables.service ufw.service
Before=network-pre.target shutdown.target
Wants=network-pre.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/goji-two-way-ping.sh start
ExecReload=/usr/local/sbin/goji-two-way-ping.sh restart
ExecStop=/usr/local/sbin/goji-two-way-ping.sh stop

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable goji-two-way-ping.service >/dev/null 2>&1 || true
  if systemctl restart goji-two-way-ping.service 2>/dev/null && nft list table inet goji_privacy >/dev/null 2>&1; then
    ok "защита от ping включена (echo-request: $([[ $mode == drop ]] && echo блок || echo 'лимит 5/с'), timestamp: блок)"
  else
    systemctl disable goji-two-way-ping.service >/dev/null 2>&1 || true
    warn "защиту от ping загрузить не удалось (контейнер без nftables?) — смотрите: journalctl -u goji-two-way-ping"
  fi
}

# ---------------------------------------------------------------- Traffic Control (opt-in)
harden_guard() {
  if ! command -v nft >/dev/null; then
    apt-get install -y -qq nftables >/dev/null 2>&1 || { warn "не удалось установить nftables — Traffic Control пропущен"; return 0; }
  fi
  command -v python3 >/dev/null || apt-get install -y -qq python3-minimal >/dev/null 2>&1 || { warn "нет python3 — Traffic Control пропущен"; return 0; }
  local ssh_csv="${SSH_PORTS_DETECTED:-}" admin="" ip
  if [[ -z "$ssh_csv" ]]; then
    ssh_csv="${SSH_PORT:-$(sshd -T 2>/dev/null | awk '$1=="port"{printf "%s ", $2}')}"
    ssh_csv="${ssh_csv% }"; ssh_csv="${ssh_csv:-22}"
  fi
  # administrator = the address of the current SSH session, plus any --admin-ip
  [[ -n "${SSH_CONNECTION:-}" ]] && admin="${SSH_CONNECTION%% *}"
  for ip in "${ADMIN_IPS[@]}"; do admin="$admin $ip"; done
  admin="${admin# }"
  [[ -n "$admin" ]] || warn "IP администратора не определён (не SSH-сессия) — задайте --admin-ip; порт SSH остаётся открытым для всех"
  mkdir -p /etc/goji-guard /var/lib/goji-guard /usr/local/sbin
  printf '# Managed by goji-node-setup; edit and run: goji-guard apply\nENABLED="1"\nADMIN_IPS="%s"\nPANEL_IPS="%s"\nSSH_PORTS="%s"\nEXEMPT_PORTS="80"\n' \
    "$admin" "$PANEL_IP" "$ssh_csv" > /etc/goji-guard/config
  cat > /usr/local/sbin/goji-guard <<'PYEOF'
#!/usr/bin/env python3
"""goji-guard — блокировка входящих из сетей сканеров для goji-node-setup (таблица nftables inet goji_guard).

Скачивает публичные списки сканеров, проверяет их и отбрасывает новые входящие
пакеты из этих сетей. Администратор, панель, SSH и исключённые порты никогда
не блокируются. Команды: status | update | apply | on | off | check
"""
import ipaddress
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

CONF = "/etc/goji-guard/config"
STATE = "/var/lib/goji-guard"
TABLE = "goji_guard"
BASE = "https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/"
LISTS = ("antiscanner", "government_networks", "skipa")
MAX_BYTES = 8 * 1024 * 1024
MAX_ENTRIES = 150000
MAX_BAD_RATIO = 0.05
MIN_V4_PREFIX = 8     # a list may never contain something broader than a /8 ...
MIN_V6_PREFIX = 16    # ... or an IPv6 /16: that would cut off half the internet


def load_conf():
    conf = {"ENABLED": "1", "ADMIN_IPS": "", "PANEL_IPS": "", "SSH_PORTS": "22", "EXEMPT_PORTS": "80"}
    try:
        with open(CONF, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    conf[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return conf


def write_conf_value(key, value):
    lines, found = [], False
    try:
        with open(CONF, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except FileNotFoundError:
        pass
    for i, line in enumerate(lines):
        if line.split("=", 1)[0].strip() == key:
            lines[i] = f'{key}="{value}"'
            found = True
    if not found:
        lines.append(f'{key}="{value}"')
    atomic_write(CONF, "\n".join(lines) + "\n", 0o644)


def atomic_write(path, text, mode=0o644):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def parse_list(text):
    """Return (networks, bad_lines, nonblank_lines). Raises ValueError on suspicious content."""
    nets, bad, total = [], 0, 0
    for raw in text.splitlines():
        s = raw.split("#", 1)[0].strip()
        if not s:
            continue
        total += 1
        try:
            n = ipaddress.ip_network(s, strict=False)
        except ValueError:
            bad += 1
            continue
        if n.version == 4 and n.prefixlen < MIN_V4_PREFIX or n.version == 6 and n.prefixlen < MIN_V6_PREFIX:
            raise ValueError(f"подозрительно широкая сеть {n}")
        # never block local / private / special ranges: provider gateways, DNS, metadata
        if n.is_private or n.is_loopback or n.is_link_local or n.is_multicast or n.is_reserved or n.is_unspecified:
            continue
        nets.append(n)
    return nets, bad, total


def fetch(name):
    class HttpsOnly(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            if not newurl.startswith("https://"):
                raise urllib.error.URLError("редирект на не-https адрес отклонён")
            return super().redirect_request(req, fp, code, msg, headers, newurl)

    opener = urllib.request.build_opener(HttpsOnly)
    req = urllib.request.Request(BASE + name + ".list", headers={"User-Agent": "goji-guard/1"})
    with opener.open(req, timeout=60) as resp:
        raw = resp.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise ValueError("список больше допустимого размера")
    return raw.decode("utf-8", "strict")


def cache_path(name):
    return os.path.join(STATE, name + ".list")


def update_lists():
    ok = 0
    for name in LISTS:
        try:
            nets, bad, total = parse_list(fetch(name))
            if not nets:
                raise ValueError("нет корректных сетей")
            if total and bad / total > MAX_BAD_RATIO:
                raise ValueError(f"{bad} из {total} строк не являются IP/CIDR")
            if len(nets) > MAX_ENTRIES:
                raise ValueError(f"записей ({len(nets)}) больше лимита")
            atomic_write(cache_path(name), "\n".join(str(n) for n in nets) + "\n")
            print(f"[+] {name}: сетей — {len(nets)}")
            ok += 1
        except Exception as exc:  # network errors, bad data - keep the previous copy
            have = os.path.exists(cache_path(name))
            print(f"[!] {name}: {exc}; " + ("оставляю прежнюю копию" if have else "сохранённой копии нет"), file=sys.stderr)
    return ok


def read_cached():
    v4, v6, used = [], [], 0
    for name in LISTS:
        try:
            with open(cache_path(name), encoding="utf-8") as fh:
                nets, _, _ = parse_list(fh.read())
        except (FileNotFoundError, ValueError):
            continue
        used += 1
        for n in nets:
            (v4 if n.version == 4 else v6).append(n)
    if len(v4) + len(v6) > MAX_ENTRIES * len(LISTS):
        raise ValueError("сохранённые списки превышают лимит")
    return ipaddress.collapse_addresses(v4), ipaddress.collapse_addresses(v6), used


def split_allow(conf):
    a4, a6 = [], []
    for token in (conf["ADMIN_IPS"] + " " + conf["PANEL_IPS"]).replace(",", " ").split():
        n = ipaddress.ip_network(token, strict=False)
        (a4 if n.version == 4 else a6).append(n)
    return a4, a6


def ports(value):
    out = []
    for p in value.replace(",", " ").split():
        if not (p.isdigit() and 0 < int(p) < 65536):
            raise ValueError(f"некорректный порт '{p}'")
        out.append(p)
    return out


def build_ruleset(conf):
    v4, v6, used = read_cached()
    v4, v6 = list(v4), list(v6)
    if used == 0:
        raise ValueError("нет сохранённых списков; выполните: goji-guard update")
    a4, a6 = split_allow(conf)
    skip = ports(conf["SSH_PORTS"]) + ports(conf["EXEMPT_PORTS"])

    def elems(items):
        return ("elements = { " + ", ".join(str(i) for i in items) + " }") if items else ""

    out = [
        f"add table inet {TABLE}",
        f"delete table inet {TABLE}",
        f"table inet {TABLE} {{",
        f"  set allow4 {{ type ipv4_addr; flags interval; {elems(a4)} }}",
        f"  set allow6 {{ type ipv6_addr; flags interval; {elems(a6)} }}",
        f"  set block4 {{ type ipv4_addr; flags interval; {elems(v4)} }}",
        f"  set block6 {{ type ipv6_addr; flags interval; {elems(v6)} }}",
        "  chain input {",
        "    type filter hook input priority -150; policy accept;",
        '    iifname "lo" accept',
        "    ct state established,related accept",
        "    ip saddr @allow4 accept",
        "    ip6 saddr @allow6 accept",
    ]
    if skip:
        out.append("    tcp dport { " + ", ".join(skip) + " } accept")
    out += [
        "    ip saddr @block4 counter drop",
        "    ip6 saddr @block6 counter drop",
        "  }",
        "}",
        "",
    ]
    return "\n".join(out), len(v4), len(v6)


def nft(*args, stdin=None):
    return subprocess.run(["nft", *args], input=stdin, text=True, capture_output=True)


def remove_table():
    nft("delete", "table", "inet", TABLE)


def apply():
    conf = load_conf()
    if conf["ENABLED"] != "1":
        remove_table()
        print("[*] Traffic Control выключен")
        return 0
    try:
        text, n4, n6 = build_ruleset(conf)
    except ValueError as exc:
        print(f"[x] {exc}", file=sys.stderr)
        return 1
    fd, tmp = tempfile.mkstemp(prefix="goji-guard-", suffix=".nft")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        chk = nft("-c", "-f", tmp)
        if chk.returncode != 0:
            print("[x] nft отклонил набор правил, прежние правила остаются:\n" + chk.stderr, file=sys.stderr)
            return 1
        res = nft("-f", tmp)
        if res.returncode != 0:
            print("[x] не удалось загрузить набор правил:\n" + res.stderr, file=sys.stderr)
            return 1
    finally:
        os.unlink(tmp)
    print(f"[+] Traffic Control включён: заблокировано сетей IPv4 — {n4}, IPv6 — {n6}")
    return 0


def table_text():
    r = nft("list", "table", "inet", TABLE)
    return r.stdout if r.returncode == 0 else None


def status():
    conf = load_conf()
    txt = table_text()
    print(f"включён в конфиге : {'да' if conf['ENABLED'] == '1' else 'нет'}")
    print(f"таблица nftables   : {'загружена' if txt else 'не загружена'}")
    for name in LISTS:
        p = cache_path(name)
        if os.path.exists(p):
            with open(p, encoding="utf-8") as fh:
                n = sum(1 for _ in fh)
            age = int((time.time() - os.path.getmtime(p)) / 3600)
            print(f"{name:<20}: сетей {n}, обновлён {age} ч назад")
        else:
            print(f"{name:<20}: копии нет")
    print(f"исключения         : админ/панель [{conf['ADMIN_IPS']} {conf['PANEL_IPS']}], tcp ports {conf['SSH_PORTS']} {conf['EXEMPT_PORTS']}")
    if txt:
        pk = [int(x.split()[1]) for x in txt.replace("\n", " ").split("counter ")[1:] if x.split()[0] == "packets"]
        print(f"отброшено пакетов  : {sum(pk)}")
    return 0


def check():
    conf = load_conf()
    if conf["ENABLED"] != "1":
        print("off")
        return 0
    txt = table_text()
    if not txt:
        print("таблица не загружена", file=sys.stderr)
        return 1
    print("ok")
    return 0


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if os.geteuid() != 0:
        print("запустите от root", file=sys.stderr)
        return 1
    if cmd == "status":
        return status()
    if cmd == "update":
        os.makedirs(STATE, mode=0o755, exist_ok=True)
        got = update_lists()
        if got == 0 and not any(os.path.exists(cache_path(n)) for n in LISTS):
            print("[x] не удалось скачать ни одного списка", file=sys.stderr)
            return 1
        return apply()
    if cmd == "apply":
        return apply()
    if cmd in ("on", "off"):
        write_conf_value("ENABLED", "1" if cmd == "on" else "0")
        return apply()
    if cmd == "check":
        return check()
    print(__doc__)
    return 0 if cmd in ("-h", "--help", "help") else 1


if __name__ == "__main__":
    sys.exit(main())
PYEOF
  chmod 755 /usr/local/sbin/goji-guard
  cat > /etc/systemd/system/goji-guard.service <<'UNIT'
[Unit]
Description=Goji Traffic Control: restore blocklist rules from the local cache
DefaultDependencies=no
After=local-fs.target nftables.service ufw.service
Before=network-pre.target shutdown.target
Wants=network-pre.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/goji-guard apply
ExecStop=-/usr/sbin/nft delete table inet goji_guard

[Install]
WantedBy=multi-user.target
UNIT
  cat > /etc/systemd/system/goji-guard-update.service <<'UNIT'
[Unit]
Description=Goji Traffic Control: refresh blocklists
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/goji-guard update
UNIT
  cat > /etc/systemd/system/goji-guard-update.timer <<'UNIT'
[Unit]
Description=Goji Traffic Control: daily blocklist refresh

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable goji-guard.service goji-guard-update.timer >/dev/null 2>&1 || true
  systemctl start goji-guard-update.timer >/dev/null 2>&1 || true
  if /usr/local/sbin/goji-guard update && nft list table inet goji_guard >/dev/null 2>&1; then
    ok "Traffic Control включён (исключены: админ [${admin:-нет}], панель [${PANEL_IP:-нет}], tcp-порты $ssh_csv и 80; управление: goji-guard status|update|on|off)"
  else
    warn "Traffic Control пока не включён (списки недоступны?) — ежедневный таймер повторит; вручную: goji-guard update"
  fi
}

# ---------------------------------------------------------------- Remnawave panel (API)
# Creates/reuses the config profile, makes it active on this node and creates/updates the
# host - the manual steps from "Профиль Xray в Remnawave" / "Хост в Remnawave" in INSTALL.md.
install_profile_file() {
  mkdir -p "$GOJI_SHARE"
  echo "__PROFILE_B64__" | base64 -d > "$GOJI_SHARE/xray-node-profile.json"
}

install_panel_tool() {
  install_profile_file
  cat > /usr/local/sbin/goji-panel <<'PYEOF'
#!/usr/bin/env python3
"""goji-panel — настройка панели Remnawave для ноды Goji XHTTP+TLS через REST API.

  goji-panel sync --url https://panel.example.com --domain node.example.com [параметры]

Создаёт (или переиспользует) профиль конфигурации, делает его активным профилем этой ноды
и создаёт или обновляет хост. Ничего не удаляется. API-токен берётся из переменной
окружения GOJI_PANEL_TOKEN (создаётся в панели: Settings -> API tokens).
Эндпоинты и поля соответствуют контракту бэкенда Remnawave (проверено по v3.4.4).
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

PROFILE_FILE = "/usr/share/goji-node/xray-node-profile.json"


class ApiError(Exception):
    pass


class Panel:
    def __init__(self, base, token):
        self.base = base.rstrip("/")
        self.token = token

    def call(self, method, path, body=None):
        url = self.base + path
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": "Bearer " + self.token,
            "Content-Type": "application/json",
            "Accept": "application/json",
            # the panel refuses requests that do not look like they came through an HTTPS reverse proxy
            "X-Forwarded-For": "127.0.0.1",
            "X-Forwarded-Proto": "https",
            "User-Agent": "goji-panel/1",
        })
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:400]
            if exc.code in (401, 403):
                raise ApiError(f"{method} {path}: HTTP {exc.code} — токен отклонён или не хватает прав. {detail}")
            raise ApiError(f"{method} {path}: HTTP {exc.code} {detail}")
        except (urllib.error.URLError, OSError) as exc:
            raise ApiError(f"{method} {path}: {exc}")
        if not raw:
            return None
        try:
            return json.loads(raw)
        except ValueError:
            raise ApiError(f"{method} {path}: ответ не в формате JSON (это точно адрес панели в --url?)")

    def get(self, path):
        return self.call("GET", path)["response"]


def load_profile(xray_port, xpath):
    with open(PROFILE_FILE, encoding="utf-8") as fh:
        cfg = json.load(fh)
    inbound = cfg["inbounds"][0]
    inbound["port"] = xray_port
    inbound["streamSettings"]["xhttpSettings"]["path"] = xpath
    return cfg


def log(msg):
    print(msg, flush=True)


def find_inbound(profile, tag):
    for ib in profile.get("inbounds", []):
        if ib.get("tag") == tag:
            return ib
    return None


def sync(args, token):
    panel = Panel(args.url, token)
    dry = args.dry_run
    desired = load_profile(args.xray_port, args.path)
    tag = desired["inbounds"][0]["tag"]

    # ---- config profile
    profiles = panel.get("/api/config-profiles")["configProfiles"]
    prof = next((p for p in profiles if p["name"] == args.profile_name), None)
    if prof is None:
        log(f"[*] профиль '{args.profile_name}': создаю")
        if dry:
            prof = {"uuid": "(new)", "inbounds": [{"uuid": "(new)", "tag": tag}], "config": desired}
        else:
            prof = panel.call("POST", "/api/config-profiles", {"name": args.profile_name, "config": desired})["response"]
        log("[+] профиль создан")
    elif prof.get("config") == desired:
        log(f"[+] профиль '{args.profile_name}': уже актуален")
    elif args.overwrite_profile:
        log(f"[*] профиль '{args.profile_name}': отличается от профиля Goji, перезаписываю (--panel-overwrite-profile)")
        if not dry:
            prof = panel.call("PATCH", "/api/config-profiles", {"uuid": prof["uuid"], "config": desired})["response"]
        log("[+] профиль обновлён")
    else:
        log(f"[!] профиль '{args.profile_name}' уже есть и отличается от профиля Goji; оставляю как есть "
            "(чтобы заменить конфиг, используйте --panel-overwrite-profile)")
    inbound = find_inbound(prof, tag)
    if inbound is None:
        raise ApiError(f"в профиле '{args.profile_name}' нет inbound с тегом '{tag}'")
    live_cfg = prof.get("config") if isinstance(prof.get("config"), dict) else desired
    live_port = (live_cfg.get("inbounds") or [{}])[0].get("port")
    if live_port != args.xray_port:
        log(f"[!] существующий профиль слушает порт {live_port}, а nginx будет проксировать на {args.xray_port}: "
            "запустите заново с --xray-port или --panel-overwrite-profile")

    # ---- node
    node = None
    nodes = panel.get("/api/nodes")
    if args.node:
        node = next((n for n in nodes if args.node in (n["name"], n["uuid"])), None)
        if node is None:
            raise ApiError(f"нода '{args.node}' не найдена в панели")
    else:
        addrs = {a.lower() for a in args.node_address if a}
        cand = [n for n in nodes if n["address"].lower() in addrs]
        if len(cand) == 1:
            node = cand[0]
        elif len(cand) > 1:
            names = ", ".join(n["name"] for n in cand)
            raise ApiError(f"этому серверу соответствуют несколько нод ({names}); выберите одну через --panel-node")
    if node is None:
        log("[!] в панели не найдена нода с адресом этого сервера; профиль и хост готовы, "
            "назначьте профиль ноде вручную (или укажите --panel-node ИМЯ)")
    else:
        active = node["configProfile"]["activeConfigProfileUuid"]
        active_ib = {i["uuid"] for i in node["configProfile"]["activeInbounds"]}
        if active == prof["uuid"] and inbound["uuid"] in active_ib:
            log(f"[+] нода '{node['name']}': профиль уже активен")
        else:
            log(f"[*] нода '{node['name']}': переключаю активный профиль "
                f"(был {active or 'нет'}) — Xray на ноде перезапустится")
            if not dry:
                panel.call("PATCH", "/api/nodes", {"uuid": node["uuid"], "configProfile": {
                    "activeConfigProfileUuid": prof["uuid"], "activeInbounds": [inbound["uuid"]]}})
            log("[+] профиль ноды переключён")

    # ---- host
    remark = args.host_remark or f"Goji {args.domain}"
    fields = {
        "remark": remark, "address": args.domain, "port": 443, "path": args.path, "sni": args.domain,
        "alpn": "h2", "fingerprint": "firefox", "securityLayer": "TLS", "isDisabled": False,
        "inbound": {"configProfileUuid": prof["uuid"], "configProfileInboundUuid": inbound["uuid"]},
    }
    hosts = panel.get("/api/hosts")
    host = next((h for h in hosts if h["remark"] == remark), None) or next(
        (h for h in hosts if h["address"].lower() == args.domain and h["port"] == 443 and h.get("path") == args.path), None)
    nodes_field = sorted(set((host or {}).get("nodes", [])) | ({node["uuid"]} if node else set()))
    if nodes_field:
        fields["nodes"] = nodes_field
    if host is None:
        log(f"[*] хост '{remark}': создаю")
        if not dry:
            host = panel.call("POST", "/api/hosts", fields)["response"]
        log("[+] хост создан")
    else:
        changed = {k: v for k, v in fields.items()
                   if (sorted(host.get(k) or []) != v if k == "nodes" else host.get(k) != v)}
        if not changed:
            log(f"[+] хост '{host['remark']}': уже актуален")
        else:
            log(f"[*] хост '{host['remark']}': обновляю {', '.join(sorted(changed))}")
            if not dry:
                panel.call("PATCH", "/api/hosts", {"uuid": host["uuid"], **fields})
            log("[+] хост обновлён")

    # ---- squads (users only receive hosts of inbounds that are in their internal squad)
    if args.squad:
        squads = panel.get("/api/internal-squads")["internalSquads"]
        for name in args.squad:
            sq = next((s for s in squads if s["name"] == name), None)
            if sq is None:
                log(f"[!] internal squad '{name}' не найден — пропущен")
                continue
            have = [i["uuid"] for i in sq["inbounds"]]
            if inbound["uuid"] in have:
                log(f"[+] squad '{name}': inbound уже включён")
                continue
            log(f"[*] squad '{name}': добавляю inbound (существующие сохраняются)")
            if not dry:
                panel.call("PATCH", "/api/internal-squads", {"uuid": sq["uuid"], "inbounds": have + [inbound["uuid"]]})
            log("[+] squad обновлён")
    else:
        log("[i] --panel-squad не задан: пользователи получат этот хост только после добавления inbound в internal squad")
    if dry:
        log("[i] пробный запуск: ничего не изменено")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="goji-panel", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("sync", help="создать/обновить профиль, назначение ноде и хост")
    s.add_argument("--url", required=True, help="адрес панели, например https://panel.example.com")
    s.add_argument("--domain", required=True)
    s.add_argument("--xray-port", type=int, default=10443)
    s.add_argument("--path", default="/api/v2/telemetry/")
    s.add_argument("--node", default="", help="имя или uuid ноды (по умолчанию ищется по --node-address)")
    s.add_argument("--node-address", action="append", default=[], help="адрес(а), с которыми нода зарегистрирована")
    s.add_argument("--profile-name", default="Goji XHTTP-TLS")
    s.add_argument("--host-remark", default="")
    s.add_argument("--squad", action="append", default=[], help="имя internal squad, в который добавить inbound (можно повторять)")
    s.add_argument("--overwrite-profile", action="store_true")
    s.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)
    token = os.environ.get("GOJI_PANEL_TOKEN", "").strip()
    if not token:
        print("переменная GOJI_PANEL_TOKEN не задана", file=sys.stderr)
        return 1
    args.domain = args.domain.lower()
    if not urllib.parse.urlparse(args.url).scheme in ("http", "https"):
        print("--url должен начинаться с http:// или https://", file=sys.stderr)
        return 1
    try:
        return sync(args, token)
    except ApiError as exc:
        print(f"[x] {exc}", file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError) as exc:
        print(f"[x] неожиданный ответ или локальная ошибка: {exc!r}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
PYEOF
  chmod 755 /usr/local/sbin/goji-panel
}

panel_sync() {
  [[ -n "$PANEL_URL" ]] || return 0
  if [[ -z "$PANEL_TOKEN" ]]; then
    warn "шаг панели пропущен: нет API-токена (GOJI_PANEL_TOKEN). Позже: GOJI_PANEL_TOKEN=... goji-panel sync --url $PANEL_URL --domain $DOMAIN"
    return 0
  fi
  command -v python3 >/dev/null || { warn "нет python3 — шаг панели пропущен"; return 0; }
  install_panel_tool
  local args=(sync --url "$PANEL_URL" --domain "$DOMAIN" --xray-port "$XRAY_PORT" --path "$XPATH"
              --profile-name "$PANEL_PROFILE" --node-address "$DOMAIN" --node-address "${MY_IP:-}" --node-address "${DNS_IP:-}")
  [[ -z "$PANEL_NODE" ]] || args+=(--node "$PANEL_NODE")
  [[ -z "$PANEL_HOST" ]] || args+=(--host-remark "$PANEL_HOST")
  [[ $PANEL_OVERWRITE -eq 0 ]] || args+=(--overwrite-profile)
  local sq
  for sq in "${PANEL_SQUADS[@]}"; do args+=(--squad "$sq"); done
  info "Настраиваю панель Remnawave ($PANEL_URL)"
  if GOJI_PANEL_TOKEN="$PANEL_TOKEN" /usr/local/sbin/goji-panel "${args[@]}"; then
    ok "панель настроена: профиль, нода и хост"
    PANEL_DONE=1
  else
    warn "настройка панели не удалась — сделайте вручную (профиль ниже, INSTALL.md) или устраните причину и запустите: bash install.sh --resume"
  fi
}

# Команда `goji-node` (меню и проверка) и совместимая обёртка goji-node-check.
install_check_command() {
  {
    echo '#!/usr/bin/env bash'
    echo 'export LC_ALL=C.UTF-8'
    declare -p GOJI_ETC GOJI_SHARE GOJI_WEBROOT
    declare -f gj_row gj_title gjc_load goji_tpl_desc gjc_web gjc_node gjc_system gjc_security gjc_summary \
      goji_check goji_ports goji_render_profile goji_show_profile goji_deploy_decoy goji_tpl_list \
      goji_tpl_choose goji_decoy goji_menu goji_main
    echo '[[ $EUID -eq 0 ]] || { echo "Запустите от root: sudo goji-node" >&2; exit 1; }'
    echo 'goji_main "$@"'
  } > /usr/local/sbin/goji-node
  chmod 755 /usr/local/sbin/goji-node
  printf '#!/bin/sh\nexec /usr/local/sbin/goji-node check "$@"\n' > /usr/local/sbin/goji-node-check
  chmod 755 /usr/local/sbin/goji-node-check
}

if [[ $HARDEN -eq 1 ]]; then
  harden_system
  harden_ssh
  harden_ping
  if [[ $GUARD_ON -eq 1 ]]; then harden_guard; else info "Traffic Control не установлен (параметр --traffic-control)"; fi
else
  info "Усиление защиты пропущено (--skip-hardening)"
fi
install_profile_file
install_check_command
panel_sync

# Готовый профиль для Remnawave: показываем сразу, пока он нужен для переключения ноды.
show_profile() {
  goji_show_profile || warn "не удалось показать профиль — команда: goji-node profile"
  PROFILE_SHOWN=1
}

# ---------------------------------------------------------------- wait for :443
# Enable nginx on 443 only when the XHTTP profile is really active: Xray listens
# on 127.0.0.1:$XRAY_PORT and nobody else holds 443. A free 443 alone is not
# enough — it is also free for a few seconds while the node container restarts
# with the old profile, and grabbing it then takes the old inbound down.
xhttp_up()  { ss -Hltn "sport = :$XRAY_PORT" | grep -q .; }
foreign443() { ss -Hltnp "sport = :443" | grep -q . && ! ss -Hltnp "sport = :443" | grep -q nginx; }
ready() { xhttp_up && ! foreign443; }
if ! ready; then
  # nginx must not hold 443 while the old profile may still need it
  rm -f "$CONF"; systemctl reload nginx
  warn "Профиль XHTTP ещё не активен (на 127.0.0.1:$XRAY_PORT никто не слушает)."
  [[ $PANEL_DONE -eq 1 ]] || show_profile
  echo "    Переключите профиль этой ноды в Remnawave на XHTTP"
  echo "    (inbound 127.0.0.1:$XRAY_PORT, xhttp, path $XPATH) и обновите хост."
  info "Жду профиль XHTTP до $WAIT с..."
  for ((i = 0; i < WAIT; i += 5)); do
    ready && break
    sleep 5
  done
  if ! ready; then
    warn "Профиль XHTTP не появился. Старый профиль продолжает работать; TLS-фронт nginx ещё не включён."
    echo "    После переключения профиля выполните:  bash install.sh --resume   (состояние: goji-node)"
    exit 2
  fi
fi

# ---------------------------------------------------------------- nginx :443
info "Включаю TLS-фронт"
# ssl_reject_handshake needs nginx >= 1.19.4; older nginx gets a catch-all that
# uses the same certificate and closes the connection (return 444).
NGINX_VER=$(nginx -v 2>&1 | sed -n 's#.*nginx/\([0-9.]*\).*#\1#p')
if [[ "$(printf '%s\n1.19.4\n' "$NGINX_VER" | sort -V | head -1)" == "1.19.4" ]]; then
  DEFAULT_SRV="    ssl_reject_handshake on;"
else
  warn "nginx $NGINX_VER старше 1.19.4: вместо ssl_reject_handshake использую catch-all сервер"
  DEFAULT_SRV="    ssl_certificate     $LIVE/fullchain.pem;
    ssl_certificate_key $LIVE/privkey.pem;
    return 444;"
fi
cat > "$CONF" <<EOF
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
$DEFAULT_SRV
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;
    server_tokens off;

    ssl_certificate     $LIVE/fullchain.pem;
    ssl_certificate_key $LIVE/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    root $WEBROOT;
    index index.html;
    error_page 404 /404.html;

    location $XPATH {
        client_max_body_size 0;
        client_body_timeout 5m;
        grpc_pass grpc://127.0.0.1:$XRAY_PORT;
        grpc_buffer_size 16k;
        grpc_socket_keepalive on;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
        grpc_set_header Host \$host;
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$remote_addr;
    }

    location = /404.html {
        internal;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
nginx -t -q
systemctl reload nginx
ok "nginx отдаёт https://$DOMAIN"

# ---------------------------------------------------------------- self-test
code=$(curl -s -o /dev/null -w '%{http_code}' --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" || true)
[[ "$code" == "200" ]] && ok "Сайт-заглушка: HTTP 200" || warn "Сайт-заглушка ответил HTTP $code"
if ss -Hltn "sport = :$XRAY_PORT" | grep -q .; then
  ok "Xray XHTTP слушает 127.0.0.1:$XRAY_PORT"
else
  warn "На 127.0.0.1:$XRAY_PORT пока никто не слушает — проверьте профиль ноды в Remnawave"
fi

ok "Установка завершена"
[[ $PROFILE_SHOWN -eq 1 ]] || show_profile

cat <<EOF

Хост в Remnawave для $DOMAIN:
  адрес / порт : $DOMAIN / 443
  network      : xhttp      path: $XPATH      mode: auto
  security     : tls        sni : $DOMAIN     alpn: h2
  fingerprint  : firefox    flow: (пусто)

Дальше управлять и проверять сервер можно командой:  goji-node
  (меню: проверка настроек, профиль для Remnawave, смена сайта-заглушки)
EOF

echo
echo "Не закрывайте эту SSH-сессию: сначала проверьте вход во второй сессии."
rc=0
goji_check || rc=$?
exit $rc
