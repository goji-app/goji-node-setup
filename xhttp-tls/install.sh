#!/usr/bin/env bash
# XHTTP + TLS front for a Remnawave node: nginx (TLS, decoy site) -> Xray XHTTP.
#
# Usage:
#   bash install.sh [domain] [--email you@example.com] [--xray-port 10443]
#                            [--path /api/v2/telemetry/] [--wait 900]
#                            [--secret-key KEY] [--node-port 2222]
#                            [--panel-ip 1.2.3.4] [--skip-node]
#                            [--template random|analytics|blog|docs|saas]
#                            [--skip-hardening] [--icmp-drop] [--ssh-port N]
#                            [--allow-port 8443[/tcp|/udp]]...
#                            [--traffic-control|--no-traffic-control] [--admin-ip IP]...
#                            [--upgrade-os|--no-upgrade-os]
#                            [--panel-url https://panel.example.com] [--panel-node NAME]
#                            [--panel-profile NAME] [--panel-host REMARK] [--panel-squad NAME]...
#                            [--panel-overwrite-profile] [--no-panel]   (token: env GOJI_PANEL_TOKEN)
#   bash install.sh --check | --resume | --version
#
# Reinstalls Remnawave Node (docker, /opt/remnanode) asking for SECRET_KEY etc.
# Xray profile is managed by Remnawave: switch the node profile to the XHTTP one
# (listen 127.0.0.1:<xray-port>, security none) — the script waits for port 443
# to become free and then enables the TLS front.
set -euo pipefail

VERSION=1.1.0
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
RESUME=0
CHECK=0

die()  { echo -e "\e[31m[x] $*\e[0m" >&2; exit 1; }
info() { echo -e "\e[36m[*] $*\e[0m"; }
ok()   { echo -e "\e[32m[+] $*\e[0m"; }
warn() { echo -e "\e[33m[!] $*\e[0m"; }

# ---------------------------------------------------------------- component report
# Also installed as /usr/local/sbin/goji-node-check (see "declare -f" below).
# Exit codes: 0 all good, 1 something is broken, 2 installed but the Xray profile is not active yet.
gj_row() { # gj_row <status ok|warn|fail> <component> <detail>
  local c=$'\e[32m✓\e[0m' w=$'\e[33m!\e[0m' f=$'\e[31m✗\e[0m' mark pad
  case "$1" in ok) mark=$c ;; warn) mark=$w ;; *) mark=$f ;; esac
  pad=$((34 - ${#2})); (( pad < 1 )) && pad=1
  printf ' %s %s%*s %s\n' "$mark" "$2" "$pad" "" "$3"
}

goji_check() {
  export LC_ALL=C.UTF-8
  local CONF_FILE=/etc/goji-node/install.conf
  [[ -r $CONF_FILE ]] || { echo "Нет сохранённой установки ($CONF_FILE). Сначала запустите install.sh." >&2; return 1; }
  # shellcheck disable=SC1090
  . "$CONF_FILE"
  local fail=0 pending=0 live="/etc/letsencrypt/live/$GOJI_DOMAIN" v code end days
  echo
  echo "Проверка Goji node — $GOJI_DOMAIN"
  echo "----------------------------------------------------------------"

  if systemctl is-active --quiet nginx 2>/dev/null; then gj_row ok "nginx" "работает"; else gj_row fail "nginx" "не запущен"; fail=1; fi

  if [[ -f $live/fullchain.pem ]]; then
    end=$(openssl x509 -enddate -noout -in "$live/fullchain.pem" 2>/dev/null | cut -d= -f2)
    days=$(( ( $(date -d "$end" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
    if (( days > 14 )); then gj_row ok "Сертификат Let's Encrypt" "действует ещё $days дн."
    elif (( days > 0 )); then gj_row warn "Сертификат Let's Encrypt" "осталось $days дн. — проверьте продление"
    else gj_row fail "Сертификат Let's Encrypt" "истёк или не читается"; fail=1; fi
  else
    gj_row fail "Сертификат Let's Encrypt" "файл не найден"; fail=1
  fi
  if grep -qs "authenticator = webroot" "/etc/letsencrypt/renewal/$GOJI_DOMAIN.conf"; then
    gj_row ok "Продление сертификата" "webroot, certbot.timer: $(systemctl is-active certbot.timer 2>/dev/null || echo unknown)"
  else
    gj_row warn "Продление сертификата" "конфигурация webroot не найдена"
  fi

  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 --resolve "$GOJI_DOMAIN:443:127.0.0.1" "https://$GOJI_DOMAIN/" 2>/dev/null || true)
  if [[ $code == 200 ]]; then gj_row ok "HTTPS :443, сайт-заглушка" "HTTP 200"; else gj_row fail "HTTPS :443, сайт-заглушка" "$([[ -z $code || $code == 000 ]] && echo нет ответа || echo "HTTP $code")"; fail=1; fi
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 --resolve "$GOJI_DOMAIN:443:127.0.0.1" "https://$GOJI_DOMAIN/goji-check-nope" 2>/dev/null || true)
  if [[ $code == 404 ]]; then gj_row ok "Неизвестный путь" "HTTP 404"; else gj_row warn "Неизвестный путь" "$([[ -z $code || $code == 000 ]] && echo нет ответа || echo "HTTP $code"), ожидался 404"; fi

  if ss -Hltn "sport = :$GOJI_XRAY_PORT" 2>/dev/null | grep -q .; then
    gj_row ok "Xray XHTTP 127.0.0.1:$GOJI_XRAY_PORT" "слушает"
  else
    gj_row warn "Xray XHTTP 127.0.0.1:$GOJI_XRAY_PORT" "профиль в панели ещё не применён"; pending=1
  fi

  if [[ -n ${GOJI_NODE_PORT:-} ]]; then
    if command -v docker >/dev/null && [[ "$(docker inspect -f '{{.State.Running}}' remnanode 2>/dev/null)" == true ]]; then
      v=$(docker inspect -f '{{.Config.Image}}' remnanode 2>/dev/null)
      gj_row ok "Remnawave Node (docker)" "запущен, образ: ${v##*/}"
    else
      gj_row fail "Remnawave Node (docker)" "контейнер remnanode не запущен"; fail=1
    fi
    if ss -Hltn "sport = :$GOJI_NODE_PORT" 2>/dev/null | grep -q .; then gj_row ok "API ноды :$GOJI_NODE_PORT" "слушает"; else gj_row warn "API ноды :$GOJI_NODE_PORT" "порт не слушается"; fi
  fi

  if [[ ${GOJI_HARDEN:-1} -eq 1 ]]; then
    if ufw status 2>/dev/null | grep -q "Status: active"; then gj_row ok "UFW" "включён, входящие закрыты по умолчанию"; else gj_row warn "UFW" "не включён"; fi
    if fail2ban-client ping >/dev/null 2>&1; then gj_row ok "Fail2ban" "работает (sshd, recidive)"; else gj_row warn "Fail2ban" "не отвечает"; fi
    v=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null); code=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    if [[ $v == bbr && $code == fq ]]; then gj_row ok "BBR + fq" "включены"; else gj_row warn "BBR + fq" "сейчас: ${v:-?} + ${code:-?}"; fi
    if swapon --noheadings 2>/dev/null | grep -q zram; then gj_row ok "ZRAM" "swap на zram активен"; else gj_row warn "ZRAM" "не активен (контейнер или отключён)"; fi
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
  else
    gj_row warn "Усиление защиты" "пропущено (--skip-hardening)"
  fi
  if [[ -f /var/run/reboot-required ]]; then gj_row warn "Перезагрузка" "нужна для применения обновлений ОС"; fi
  echo "----------------------------------------------------------------"
  if (( fail )); then echo "Итог: есть ошибки."; return 1; fi
  if (( pending )); then echo "Итог: всё установлено, ожидается применение профиля XHTTP в Remnawave."; return 2; fi
  echo "Итог: всё в порядке."
  return 0
}

# ---------------------------------------------------------------- resume / saved configuration
for a in "$@"; do
  case "$a" in
    --version) echo "goji-node-setup $VERSION"; exit 0 ;;
    --resume)  RESUME=1 ;;
    --check)   CHECK=1 ;;
  esac
done
if [[ $RESUME -eq 1 ]]; then
  [[ -r $CONF_FILE ]] || die "--resume: no saved installation ($CONF_FILE); run install.sh normally first"
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
    --panel-token)   PANEL_TOKEN="$2"; warn "--panel-token is visible in the process list; prefer GOJI_PANEL_TOKEN or the hidden prompt"; shift 2 ;;
    --panel-node)    PANEL_NODE="$2"; shift 2 ;;
    --panel-profile) PANEL_PROFILE="$2"; shift 2 ;;
    --panel-host)    PANEL_HOST="$2"; shift 2 ;;
    --panel-squad)   PANEL_SQUADS+=("$2"); shift 2 ;;
    --panel-overwrite-profile) PANEL_OVERWRITE=1; shift ;;
    --no-panel)      PANEL_MODE=0; PANEL_URL=""; shift ;;
    --no-upgrade-os) UPGRADE_MODE=0; shift ;;
    --resume|--check) shift ;;
    -h|--help)   sed -n '2,22p' "$0"; exit 0 ;;
    -*)          die "unknown option: $1" ;;
    *)           DOMAIN="$1"; shift ;;
  esac
done

[[ $EUID -eq 0 ]] || die "run as root"
if [[ $CHECK -eq 1 ]]; then rc=0; goji_check || rc=$?; exit $rc; fi
command -v apt-get >/dev/null || die "only Debian/Ubuntu (apt) is supported"
[[ "$XPATH" == /*/ ]] || die "--path must start and end with '/'"

# ---------------------------------------------------------------- lock, signals, preflight
exec 9>/run/goji-node-setup.lock
flock -n 9 || die "another goji-node-setup is already running"
trap 'exit 130' INT
trap 'exit 143' TERM

preflight() {
  [[ -d /run/systemd/system ]] || die "systemd is required"
  local id="" ver=""
  if [[ -r /etc/os-release ]]; then id=$(. /etc/os-release; echo "${ID:-}"); ver=$(. /etc/os-release; echo "${VERSION_ID:-}"); fi
  case "$id:$ver" in
    debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) ;;
    *) warn "untested OS '$id $ver' (supported: Debian 12/13, Ubuntu 22.04/24.04) — continuing" ;;
  esac
  case "$(uname -m)" in
    x86_64|aarch64) ;;
    *) warn "untested architecture $(uname -m)" ;;
  esac
  local free_kb
  free_kb=$(df -Pk / | awk 'NR==2{print $4}')
  [[ ${free_kb:-0} -ge 1048576 ]] || die "less than 1 GiB free on / — free some space first"
  if command -v ss >/dev/null && ss -Hltnp 'sport = :80' | grep -q . && ! ss -Hltnp 'sport = :80' | grep -q nginx; then
    die "port 80 is used by another service ($(ss -Hltnp 'sport = :80' | head -1 | grep -o 'users:.*' | head -1)); certbot and the redirect need it"
  fi
  command -v sshd >/dev/null || warn "sshd not found — SSH hardening will be skipped"
  [[ -n "${SSH_CONNECTION:-}" ]] || warn "not an SSH session — keep a console open until the install finishes"
}
preflight

WEBROOT=/var/www/decoy
ACME=/var/www/acme
CONF=/etc/nginx/conf.d/xhttp-tls.conf
ACME_CONF=/etc/nginx/conf.d/xhttp-acme.conf
LIVE=/etc/letsencrypt/live/$DOMAIN

# ---------------------------------------------------------------- questions
# Works with "curl ... | bash" too: prompts read from the terminal, not stdin.
ask() { # ask <var> <prompt> [default] [secret]
  local __v="$1" __p="$2" __d="${3:-}" __s="${4:-}" __a=""
  [[ -r /dev/tty ]] || die "no terminal for prompts; pass $__p via flags"
  if [[ -n "$__d" ]]; then __p="$__p [$__d]"; fi
  if [[ -n "$__s" ]]; then
    read -r -s -p "$__p: " __a </dev/tty; echo >/dev/tty
  else
    read -r -p "$__p: " __a </dev/tty
  fi
  printf -v "$__v" '%s' "${__a:-$__d}"
}

if [[ -z "$DOMAIN" ]]; then
  ask DOMAIN "Domain of this server (A-record must point here), e.g. node.example.com" ""
fi
DOMAIN="${DOMAIN,,}"
[[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || die "invalid domain: '$DOMAIN'"
LIVE=/etc/letsencrypt/live/$DOMAIN

OLD_KEY=""; OLD_PORT=""
if [[ -f "$NODE_DIR/docker-compose.yml" ]]; then
  OLD_KEY=$(sed -nE 's/.*SECRET_KEY[=:][[:space:]]*["'"'"']?([^"'"'"']+)["'"'"']?[[:space:]]*$/\1/p' "$NODE_DIR/docker-compose.yml" | head -1)
  OLD_PORT=$(sed -nE 's/.*(NODE_PORT|APP_PORT)[=:][[:space:]]*["'"'"']?([0-9]+).*/\2/p' "$NODE_DIR/docker-compose.yml" | head -1)
fi

if [[ $SKIP_NODE -eq 0 ]]; then
  if [[ -z "$SECRET_KEY" && $RESUME -eq 1 && -n "$OLD_KEY" ]]; then SECRET_KEY="$OLD_KEY"; fi
  if [[ -z "$SECRET_KEY" ]]; then
    echo "Remnawave Node will be reinstalled in $NODE_DIR."
    echo "SECRET_KEY: Panel -> Nodes -> (this node) -> copy key from docker-compose."
    if [[ -n "$OLD_KEY" ]]; then
      ask SECRET_KEY "SECRET_KEY (Enter = keep current)" "" secret
      SECRET_KEY="${SECRET_KEY:-$OLD_KEY}"
    else
      ask SECRET_KEY "SECRET_KEY" "" secret
    fi
  fi
  [[ -n "$SECRET_KEY" ]] || die "SECRET_KEY is empty"
  [[ -n "$NODE_PORT" ]] || ask NODE_PORT "NODE_PORT (panel -> node API)" "${OLD_PORT:-2222}"
  [[ "$NODE_PORT" =~ ^[0-9]+$ ]] || die "NODE_PORT must be a number"
  [[ -n "$PANEL_IP" || $RESUME -eq 1 ]] || ask PANEL_IP "Panel IP to allow on NODE_PORT (Enter = skip firewall rule)" ""
  if [[ -z "$EMAIL" && $RESUME -eq 0 ]]; then ask EMAIL "E-mail for Let's Encrypt (Enter = none)" ""; fi
fi

# Traffic Control (blocklists of scanner networks) is opt-in.
if [[ $HARDEN -eq 1 ]]; then
  if [[ -z "$GUARD_MODE" ]]; then
    GUARD_MODE=0
    if [[ -r /dev/tty ]]; then
      read -r -p "Install Traffic Control (daily-updated blocklists of scanner networks, admin/panel/SSH are exempt)? [y/N]: " __g </dev/tty || true
      [[ "${__g:-}" =~ ^[yYдД] ]] && GUARD_MODE=1
    fi
  fi
  GUARD_ON=$GUARD_MODE
fi

# Remnawave panel: profile, node assignment and host through the panel API (opt-in).
if [[ "$PANEL_MODE" != 0 ]]; then
  if [[ -z "$PANEL_URL" && "$PANEL_MODE" != 1 && $RESUME -eq 0 && -r /dev/tty ]]; then
    read -r -p "Configure the Remnawave panel automatically (profile, node, host) via its API? [y/N]: " __p </dev/tty || true
    [[ "${__p:-}" =~ ^[yYдД] ]] && PANEL_MODE=1
  fi
  if [[ "$PANEL_MODE" == 1 ]]; then
    [[ -n "$PANEL_URL" ]] || ask PANEL_URL "Panel address, e.g. https://panel.example.com" ""
    PANEL_URL="${PANEL_URL%/}"
    [[ "$PANEL_URL" =~ ^https?://[^[:space:]]+$ ]] || die "invalid panel URL: '$PANEL_URL'"
    if [[ -z "$PANEL_TOKEN" && $RESUME -eq 0 ]]; then
      ask PANEL_TOKEN "Panel API token (hidden; created in the panel's API tokens)" "" secret
    fi
    [[ -n "$PANEL_TOKEN" ]] || warn "no panel API token — the panel step will be skipped (set GOJI_PANEL_TOKEN and use --resume)"
  fi
fi

# Installing updates of the current OS release (apt upgrade, not a release upgrade).
if [[ -z "$UPGRADE_MODE" ]]; then
  UPGRADE_MODE=0
  if [[ -r /dev/tty ]]; then
    read -r -p "Install available updates of this OS release (apt upgrade) first? [Y/n]: " __u </dev/tty || true
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
  info "resume: Remnawave Node is already running — not reinstalling it"
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
  plan=$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null) || { warn "apt could not simulate the upgrade — skipped"; return 0; }
  removed=$(grep -c '^Remv ' <<< "$plan" || true)
  upgraded=$(grep -c '^Inst ' <<< "$plan" || true)
  if [[ ${removed:-0} -gt 0 ]]; then
    warn "the upgrade plan would remove $removed package(s) — not upgrading; review with: apt-get -s upgrade"
    return 0
  fi
  if [[ ${upgraded:-0} -eq 0 ]]; then ok "system is up to date"; return 0; fi
  info "Installing $upgraded package update(s) of this OS release"
  if NEEDRESTART_SUSPEND=1 apt-get -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade >/dev/null; then
    ok "system packages updated ($upgraded)"
    [[ -f /var/run/reboot-required ]] && warn "a reboot is required to finish the updates (kernel/libc) — reboot when convenient"
  else
    warn "apt upgrade failed — see: apt-get -f install; continuing without it"
  fi
  return 0
}
if [[ $UPGRADE_ON -eq 1 ]]; then os_upgrade; else info "OS package upgrade skipped (use --upgrade-os)"; fi

info "Installing nginx and certbot"
# nftables is installed before any firewall rule exists: its postinst may load the packaged
# /etc/nftables.conf ("flush ruleset"), which would wipe ufw/docker rules loaded earlier.
# We only need the nft binary, so a freshly installed nftables.service is disabled.
pkgs=(nginx certbot curl ca-certificates iproute2)
NFT_PREINSTALLED=0; command -v nft >/dev/null && NFT_PREINSTALLED=1
[[ $HARDEN -eq 1 ]] && pkgs+=(nftables)
[[ -n "$PANEL_URL" || $GUARD_ON -eq 1 ]] && pkgs+=(python3-minimal)
apt-get install -y -qq "${pkgs[@]}" >/dev/null
if [[ $HARDEN -eq 1 && $NFT_PREINSTALLED -eq 0 ]]; then
  systemctl disable nftables.service >/dev/null 2>&1 || true
fi
ok "nginx $(nginx -v 2>&1 | sed 's#.*/##')"

# ---------------------------------------------------------------- DNS sanity
MY_IP=$(curl -4 -fsS --max-time 5 https://api.ipify.org || true)
DNS_IP=$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}' || true)
if [[ -n "$MY_IP" && -n "$DNS_IP" && "$MY_IP" != "$DNS_IP" ]]; then
  warn "$DOMAIN resolves to $DNS_IP, but this VPS is $MY_IP — certificate issuance will fail"
fi

# ---------------------------------------------------------------- decoy site
TPL_DIR=$(mktemp -d)
trap 'rm -rf "$TPL_DIR"' EXIT
echo "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" | base64 -d | tar -xz -C "$TPL_DIR"
TEMPLATES=$(ls "$TPL_DIR")
if [[ -z "$TEMPLATE" && -f "$WEBROOT/.template" ]]; then
  TEMPLATE=$(cat "$WEBROOT/.template")          # keep the site stable on re-runs
fi
if [[ -z "$TEMPLATE" || "$TEMPLATE" == random ]]; then
  TEMPLATE=$(echo "$TEMPLATES" | shuf -n 1)
fi
[[ -d "$TPL_DIR/$TEMPLATE" ]] || die "unknown template '$TEMPLATE' (available: $(echo $TEMPLATES))"
info "Deploying decoy site '$TEMPLATE' to $WEBROOT"
mkdir -p "$WEBROOT" "$ACME"
find "$WEBROOT" -mindepth 1 -delete
cp -a "$TPL_DIR/$TEMPLATE/." "$WEBROOT/"
[[ -f "$WEBROOT/LICENSE" ]] && mv "$WEBROOT/LICENSE" "$WEBROOT/LICENSE.txt"
if [[ ! -f "$WEBROOT/404.html" ]]; then
  cat > "$WEBROOT/404.html" <<'EOF404'
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>404 Not Found</title>
<style>body{font-family:system-ui,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0;color:#333}h1{font-weight:500}</style></head>
<body><div><h1>404 Not Found</h1><p><a href="/">Home</a></p></div></body></html>
EOF404
fi
[[ -f "$WEBROOT/robots.txt" ]] || printf 'User-agent: *
Disallow: /api/
' > "$WEBROOT/robots.txt"
echo "$TEMPLATE" > "$WEBROOT/.template"
chown -R www-data:www-data "$WEBROOT" "$ACME" 2>/dev/null || true

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
  warn "nginx.service was masked — unmasking"
  rm -f "$unit"
fi
systemctl unmask nginx.service >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl enable --now nginx >/dev/null
systemctl reload nginx

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
  ok "ufw: 80/tcp and 443/tcp allowed"
fi

# ---------------------------------------------------------------- certificate
RENEW_CONF=/etc/letsencrypt/renewal/$DOMAIN.conf
ARCHIVE=/etc/letsencrypt/archive/$DOMAIN
need_cert=1
if [[ -f "$LIVE/fullchain.pem" && -f "$RENEW_CONF" ]]; then
  if grep -q "authenticator = webroot" "$RENEW_CONF"; then
    need_cert=0
    ok "Certificate for $DOMAIN already exists and renews via webroot"
  else
    info "Existing certificate renews via another method — re-issuing via webroot"
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
    warn "Unmanaged certificate files for $DOMAIN moved to $bak"
  fi
  mail_args=(--register-unsafely-without-email)
  [[ -n "$EMAIL" ]] && mail_args=(-m "$EMAIL")
  certbot certonly --webroot -w "$ACME" -d "$DOMAIN" --cert-name "$DOMAIN" \
    --agree-tos --non-interactive --force-renewal "${mail_args[@]}" >/dev/null
  ok "Certificate issued for $DOMAIN"
fi
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/sh
systemctl reload nginx
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
if certbot renew --cert-name "$DOMAIN" --dry-run >/dev/null 2>&1; then
  ok "certbot renew --dry-run passed — automatic renewal works"
else
  warn "certbot renew --dry-run failed — check port 80 and: certbot renew --dry-run"
fi

# ---------------------------------------------------------------- remnawave node
if [[ $SKIP_NODE -eq 0 ]]; then
  if ! command -v docker >/dev/null; then
    info "Installing Docker"
    curl -fsSL https://get.docker.com | sh >/dev/null
  fi
  docker compose version >/dev/null 2>&1 || die "docker compose plugin is missing"

  mkdir -p "$NODE_DIR"
  if [[ -f "$NODE_DIR/docker-compose.yml" ]]; then
    bak="$NODE_DIR/docker-compose.yml.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$NODE_DIR/docker-compose.yml" "$bak"
    info "Old compose saved to $bak"
    (cd "$NODE_DIR" && docker compose down --remove-orphans) || true
  fi
  # remove a leftover container with the same name started outside compose
  docker rm -f remnanode >/dev/null 2>&1 || true

  info "Reinstalling Remnawave Node (port $NODE_PORT)"
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
    ok "Node image pinned: $NODE_DIGEST"
  else
    warn "Could not read the image digest — compose keeps remnawave/node:latest"
  fi
  (cd "$NODE_DIR" && docker compose up -d) >/dev/null

  for ((i = 0; i < 30; i++)); do
    ss -Hltn "sport = :$NODE_PORT" | grep -q . && break
    sleep 2
  done
  if ss -Hltn "sport = :$NODE_PORT" | grep -q .; then
    ok "Remnawave Node is up on :$NODE_PORT"
  else
    warn "Node does not listen on :$NODE_PORT — see: docker compose -f $NODE_DIR/docker-compose.yml logs -t"
  fi

  if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    if [[ -n "$PANEL_IP" ]]; then
      ufw allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp >/dev/null
      ok "ufw: $NODE_PORT/tcp allowed only from $PANEL_IP"
    else
      warn "ufw is active and no panel IP given — make sure the panel can reach :$NODE_PORT"
    fi
  elif [[ -n "$PANEL_IP" ]]; then
    warn "ufw is not active — restrict :$NODE_PORT to $PANEL_IP in your firewall manually"
  fi
else
  if command -v docker >/dev/null; then
    for c in $(docker ps --format '{{.Names}}' | grep -i remna || true); do
      mode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$c")
      [[ "$mode" == "host" ]] || warn "container $c uses network '$mode' — nginx won't reach 127.0.0.1:$XRAY_PORT; set network_mode: host"
    done
  fi
fi

if ! ss -Hltn "sport = :1080" | grep -q .; then
  warn "Nothing listens on :1080 — Psiphon is down; Gemini will go DIRECT (profile falls back automatically)"
fi

# ---------------------------------------------------------------- hardening & tuning
# UFW, Fail2ban, ZRAM, BBR + fq, tc (fq on the uplink), sysctl tuning and
# rate-limiting of incoming ICMP echo. Every step is best-effort: a failure prints
# a warning and never aborts the node install. Skip with --skip-hardening.
harden_system() {
  local in_container=0
  systemd-detect-virt --container --quiet 2>/dev/null && in_container=1

  info "Hardening and tuning the server"
  if ! apt-get install -y -qq ufw fail2ban >/dev/null; then
    warn "could not install ufw/fail2ban — hardening skipped"
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
      warn "could not detect the SSH port — assuming 22 (use --ssh-port to override)"
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
    warn "BBR is not available in this kernel — keeping the current congestion control"
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
    ok "sysctl tuning applied ($(sysctl -n net.ipv4.tcp_congestion_control)/$(sysctl -n net.core.default_qdisc))"
  else
    warn "some sysctl keys were rejected (container/VPS limits) — the rest is applied; see: sysctl -p $SYSCTL"
  fi

  # ---- Traffic Control: fq on the uplink (default_qdisc only covers new interfaces)
  if [[ $in_container -eq 1 ]]; then
    warn "container detected — skipping tc and ZRAM"
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
      ok "tc: fq on the uplink interface"
    else
      warn "goji-tc.service failed — see: systemctl status goji-tc"
    fi
    if systemctl enable --now goji-zram.service >/dev/null 2>&1; then
      ok "ZRAM swap enabled ($(swapon --noheadings --show=NAME,SIZE | grep zram | tr -s ' ' | head -1))"
    else
      warn "ZRAM is not available (kernel without zram?) — see: systemctl status goji-zram"
    fi
  fi

  # ---- UFW (+ ICMP echo limiting). An already active ufw keeps its defaults.
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    warn "firewalld is active — ufw and ICMP rules skipped"
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
        warn "no --panel-ip: $np/tcp is open to everyone so the panel can reach the node; pass --panel-ip to restrict it"
        ufw allow "$np/tcp" >/dev/null
      fi
    fi
    for p in "${EXTRA_PORTS[@]}"; do
      if [[ "$p" =~ ^[0-9]+(/(tcp|udp))?$ ]]; then
        ufw allow "$p" >/dev/null
      else
        warn "ignoring invalid --allow-port '$p' (use 8443 or 8443/tcp)"
      fi
    done
    # Public ports already served by the Xray core (other inbounds of the profile).
    while read -r proto port; do
      [[ -n "$port" ]] || continue
      ufw allow "$port/$proto" >/dev/null && info "ufw: keeping $port/$proto (listened by xray)"
    done < <(ss -Hltunp 2>/dev/null | awk '$5 !~ /^(127\.|\[::1\]|::1)/ && /xray|rw-core/ {n=split($5,a,":"); print $1, a[n]}' | sort -u)

    if [[ $was_active -eq 1 ]]; then
      ufw reload >/dev/null || warn "ufw reload failed — check /etc/ufw/before.rules"
    else
      ufw --force enable >/dev/null || warn "ufw failed to enable"
    fi
    if ufw status | grep -q "Status: active"; then
      ok "ufw active (ssh: ${ssh_ports[*]}, 80, 443$([[ -n "$np" ]] && echo ", $np"))"
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
      ok "fail2ban running (jails: sshd, recidive)"
    else
      warn "fail2ban did not start — see: journalctl -u fail2ban"
    fi
  else
    rm -f "$F2B"
    warn "fail2ban config test failed — jail file removed; see: fail2ban-client -t"
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
  warn "SSH hardening rolled back — previous configuration restored"
}

harden_ssh() {
  local dropin=/etc/ssh/sshd_config.d/00-goji-hardening.conf bk=/var/backups/goji-node had=0 tmp bad=0 kv k u
  command -v sshd >/dev/null || { warn "sshd not found — SSH hardening skipped"; return 0; }
  if ! grep -qsE '^[[:space:]]*Include[[:space:]]+.*sshd_config\.d' /etc/ssh/sshd_config; then
    warn "sshd_config has no Include for sshd_config.d — SSH hardening skipped"; return 0
  fi
  [[ ! -L $dropin ]] || { warn "$dropin is a symlink — SSH hardening skipped"; return 0; }
  mkdir -p /run/sshd "$bk" /etc/ssh/sshd_config.d; chmod 700 "$bk"
  sshd -t 2>/dev/null || { warn "current sshd configuration is invalid — SSH hardening skipped"; return 0; }
  sshd -T > "$bk/sshd-before.txt" 2>/dev/null || { warn "sshd -T failed — SSH hardening skipped"; return 0; }
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
    grep -qx "$kv" "$bk/sshd-after.txt" || { bad=1; warn "effective sshd setting differs from '$kv' (an earlier rule wins)"; }
  done
  for k in port allowtcpforwarding passwordauthentication pubkeyauthentication permitrootlogin kbdinteractiveauthentication authenticationmethods; do
    if [[ "$(grep -E "^$k " "$bk/sshd-before.txt" || true)" != "$(grep -E "^$k " "$bk/sshd-after.txt" || true)" ]]; then
      bad=1; warn "SSH setting '$k' would change"
    fi
  done
  if [[ $bad -eq 1 ]]; then ssh_rollback "$dropin" "$had" "$bk"; return 0; fi

  for u in ssh.service sshd.service; do
    if systemctl is-active --quiet "$u"; then
      systemctl try-reload-or-restart "$u" >/dev/null 2>&1 || { ssh_rollback "$dropin" "$had" "$bk"; return 0; }
      break
    fi
  done
  ok "SSH: MaxAuthTries 4, LoginGraceTime 30, no agent/tunnel/X11 forwarding (login method unchanged)"
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
    apt-get install -y -qq nftables >/dev/null 2>&1 || { warn "could not install nftables — ping protection skipped"; return 0; }
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
    ok "ping protection active (echo-request: $([[ $mode == drop ]] && echo dropped || echo 'limited to 5/s'), timestamp: dropped)"
  else
    systemctl disable goji-two-way-ping.service >/dev/null 2>&1 || true
    warn "ping protection could not be loaded (container without nftables?) — see: journalctl -u goji-two-way-ping"
  fi
}

# ---------------------------------------------------------------- Traffic Control (opt-in)
harden_guard() {
  if ! command -v nft >/dev/null; then
    apt-get install -y -qq nftables >/dev/null 2>&1 || { warn "could not install nftables — Traffic Control skipped"; return 0; }
  fi
  command -v python3 >/dev/null || apt-get install -y -qq python3-minimal >/dev/null 2>&1 || { warn "python3 is missing — Traffic Control skipped"; return 0; }
  local ssh_csv="${SSH_PORTS_DETECTED:-}" admin="" ip
  if [[ -z "$ssh_csv" ]]; then
    ssh_csv="${SSH_PORT:-$(sshd -T 2>/dev/null | awk '$1=="port"{printf "%s ", $2}')}"
    ssh_csv="${ssh_csv% }"; ssh_csv="${ssh_csv:-22}"
  fi
  # administrator = the address of the current SSH session, plus any --admin-ip
  [[ -n "${SSH_CONNECTION:-}" ]] && admin="${SSH_CONNECTION%% *}"
  for ip in "${ADMIN_IPS[@]}"; do admin="$admin $ip"; done
  admin="${admin# }"
  [[ -n "$admin" ]] || warn "no administrator IP detected (not an SSH session) — pass --admin-ip; SSH port stays open for everyone"
  mkdir -p /etc/goji-guard /var/lib/goji-guard /usr/local/sbin
  printf '# Managed by goji-node-setup; edit and run: goji-guard apply\nENABLED="1"\nADMIN_IPS="%s"\nPANEL_IPS="%s"\nSSH_PORTS="%s"\nEXEMPT_PORTS="80"\n' \
    "$admin" "$PANEL_IP" "$ssh_csv" > /etc/goji-guard/config
  cat > /usr/local/sbin/goji-guard <<'PYEOF'
#!/usr/bin/env python3
"""goji-guard - host ingress blocklist for goji-node-setup (nftables table inet goji_guard).

Downloads public scanner lists, validates them, and drops new inbound packets
from listed networks. Administrator, panel, SSH and exempt ports are never
blocked. Commands: status | update | apply | on | off | check
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
            raise ValueError(f"suspiciously broad network {n}")
        # never block local / private / special ranges: provider gateways, DNS, metadata
        if n.is_private or n.is_loopback or n.is_link_local or n.is_multicast or n.is_reserved or n.is_unspecified:
            continue
        nets.append(n)
    return nets, bad, total


def fetch(name):
    class HttpsOnly(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            if not newurl.startswith("https://"):
                raise urllib.error.URLError("redirect to non-https URL refused")
            return super().redirect_request(req, fp, code, msg, headers, newurl)

    opener = urllib.request.build_opener(HttpsOnly)
    req = urllib.request.Request(BASE + name + ".list", headers={"User-Agent": "goji-guard/1"})
    with opener.open(req, timeout=60) as resp:
        raw = resp.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise ValueError("list is larger than the size limit")
    return raw.decode("utf-8", "strict")


def cache_path(name):
    return os.path.join(STATE, name + ".list")


def update_lists():
    ok = 0
    for name in LISTS:
        try:
            nets, bad, total = parse_list(fetch(name))
            if not nets:
                raise ValueError("no valid networks")
            if total and bad / total > MAX_BAD_RATIO:
                raise ValueError(f"{bad} of {total} lines are not IP/CIDR")
            if len(nets) > MAX_ENTRIES:
                raise ValueError(f"{len(nets)} entries exceed the limit")
            atomic_write(cache_path(name), "\n".join(str(n) for n in nets) + "\n")
            print(f"[+] {name}: {len(nets)} networks")
            ok += 1
        except Exception as exc:  # network errors, bad data - keep the previous copy
            have = os.path.exists(cache_path(name))
            print(f"[!] {name}: {exc}; " + ("keeping the previous copy" if have else "no cached copy"), file=sys.stderr)
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
        raise ValueError("cached lists exceed the limit")
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
            raise ValueError(f"bad port '{p}'")
        out.append(p)
    return out


def build_ruleset(conf):
    v4, v6, used = read_cached()
    v4, v6 = list(v4), list(v6)
    if used == 0:
        raise ValueError("no cached lists; run: goji-guard update")
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
        print("[*] Traffic Control is switched off")
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
            print("[x] nft rejected the ruleset, the previous rules stay:\n" + chk.stderr, file=sys.stderr)
            return 1
        res = nft("-f", tmp)
        if res.returncode != 0:
            print("[x] could not load the ruleset:\n" + res.stderr, file=sys.stderr)
            return 1
    finally:
        os.unlink(tmp)
    print(f"[+] Traffic Control active: {n4} IPv4 and {n6} IPv6 networks blocked")
    return 0


def table_text():
    r = nft("list", "table", "inet", TABLE)
    return r.stdout if r.returncode == 0 else None


def status():
    conf = load_conf()
    txt = table_text()
    print(f"enabled in config : {'yes' if conf['ENABLED'] == '1' else 'no'}")
    print(f"nftables table    : {'loaded' if txt else 'not loaded'}")
    for name in LISTS:
        p = cache_path(name)
        if os.path.exists(p):
            with open(p, encoding="utf-8") as fh:
                n = sum(1 for _ in fh)
            age = int((time.time() - os.path.getmtime(p)) / 3600)
            print(f"{name:<20}: {n} networks, updated {age} h ago")
        else:
            print(f"{name:<20}: no cached copy")
    print(f"exempt            : admin/panel [{conf['ADMIN_IPS']} {conf['PANEL_IPS']}], tcp ports {conf['SSH_PORTS']} {conf['EXEMPT_PORTS']}")
    if txt:
        pk = [int(x.split()[1]) for x in txt.replace("\n", " ").split("counter ")[1:] if x.split()[0] == "packets"]
        print(f"dropped packets   : {sum(pk)}")
    return 0


def check():
    conf = load_conf()
    if conf["ENABLED"] != "1":
        print("off")
        return 0
    txt = table_text()
    if not txt:
        print("table is not loaded", file=sys.stderr)
        return 1
    print("ok")
    return 0


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if os.geteuid() != 0:
        print("run as root", file=sys.stderr)
        return 1
    if cmd == "status":
        return status()
    if cmd == "update":
        os.makedirs(STATE, mode=0o755, exist_ok=True)
        got = update_lists()
        if got == 0 and not any(os.path.exists(cache_path(n)) for n in LISTS):
            print("[x] no list could be downloaded", file=sys.stderr)
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
    ok "Traffic Control active (exempt: admin [${admin:-none}], panel [${PANEL_IP:-none}], tcp ports $ssh_csv and 80; manage with: goji-guard status|update|on|off)"
  else
    warn "Traffic Control is not active yet (lists unavailable?) — the daily timer will retry; manual: goji-guard update"
  fi
}

# ---------------------------------------------------------------- Remnawave panel (API)
# Creates/reuses the config profile, makes it active on this node and creates/updates the
# host - the manual steps from "Профиль Xray в Remnawave" / "Хост в Remnawave" in INSTALL.md.
install_panel_tool() {
  mkdir -p /usr/share/goji-node
  echo "ewogICJsb2ciOiB7CiAgICAiYWNjZXNzIjogIm5vbmUiLAogICAgImRuc0xvZyI6IGZhbHNlLAogICAgImxvZ2xldmVsIjogIndhcm5pbmciCiAgfSwKICAiZG5zIjogewogICAgInNlcnZlcnMiOiBbCiAgICAgICJodHRwczovLzEuMS4xLjEvZG5zLXF1ZXJ5IiwKICAgICAgImh0dHBzOi8vOC44LjguOC9kbnMtcXVlcnkiLAogICAgICAibG9jYWxob3N0IgogICAgXSwKICAgICJxdWVyeVN0cmF0ZWd5IjogIlVzZUlQdjQiCiAgfSwKICAiaW5ib3VuZHMiOiBbCiAgICB7CiAgICAgICJ0YWciOiAiWEhUVFAtVExTIiwKICAgICAgImxpc3RlbiI6ICIxMjcuMC4wLjEiLAogICAgICAicG9ydCI6IDEwNDQzLAogICAgICAicHJvdG9jb2wiOiAidmxlc3MiLAogICAgICAic2V0dGluZ3MiOiB7CiAgICAgICAgImNsaWVudHMiOiBbXSwKICAgICAgICAiZGVjcnlwdGlvbiI6ICJub25lIgogICAgICB9LAogICAgICAic25pZmZpbmciOiB7CiAgICAgICAgImVuYWJsZWQiOiB0cnVlLAogICAgICAgICJyb3V0ZU9ubHkiOiB0cnVlLAogICAgICAgICJkZXN0T3ZlcnJpZGUiOiBbCiAgICAgICAgICAiaHR0cCIsCiAgICAgICAgICAidGxzIiwKICAgICAgICAgICJxdWljIgogICAgICAgIF0KICAgICAgfSwKICAgICAgInN0cmVhbVNldHRpbmdzIjogewogICAgICAgICJuZXR3b3JrIjogInhodHRwIiwKICAgICAgICAic2VjdXJpdHkiOiAibm9uZSIsCiAgICAgICAgInhodHRwU2V0dGluZ3MiOiB7CiAgICAgICAgICAibW9kZSI6ICJhdXRvIiwKICAgICAgICAgICJwYXRoIjogIi9hcGkvdjIvdGVsZW1ldHJ5LyIKICAgICAgICB9CiAgICAgIH0KICAgIH0KICBdLAogICJvdXRib3VuZHMiOiBbCiAgICB7CiAgICAgICJ0YWciOiAiRElSRUNUIiwKICAgICAgInByb3RvY29sIjogImZyZWVkb20iLAogICAgICAic2V0dGluZ3MiOiB7CiAgICAgICAgImRvbWFpblN0cmF0ZWd5IjogIlVzZUlQdjQiCiAgICAgIH0KICAgIH0sCiAgICB7CiAgICAgICJ0YWciOiAiQkxPQ0siLAogICAgICAicHJvdG9jb2wiOiAiYmxhY2tob2xlIgogICAgfSwKICAgIHsKICAgICAgInRhZyI6ICJwc2lwaG9uLW91dCIsCiAgICAgICJwcm90b2NvbCI6ICJzb2NrcyIsCiAgICAgICJzZXR0aW5ncyI6IHsKICAgICAgICAicG9ydCI6IDEwODAsCiAgICAgICAgImFkZHJlc3MiOiAiMTcyLjE3LjAuMSIKICAgICAgfQogICAgfQogIF0sCiAgIm9ic2VydmF0b3J5IjogewogICAgInN1YmplY3RTZWxlY3RvciI6IFsKICAgICAgInBzaXBob24tb3V0IgogICAgXSwKICAgICJwcm9iZVVSTCI6ICJodHRwczovL3d3dy5nc3RhdGljLmNvbS9nZW5lcmF0ZV8yMDQiLAogICAgInByb2JlSW50ZXJ2YWwiOiAiMW0iCiAgfSwKICAicm91dGluZyI6IHsKICAgICJiYWxhbmNlcnMiOiBbCiAgICAgIHsKICAgICAgICAidGFnIjogImdvb2dsZS1iYWxhbmNlciIsCiAgICAgICAgInNlbGVjdG9yIjogWwogICAgICAgICAgInBzaXBob24tb3V0IgogICAgICAgIF0sCiAgICAgICAgImZhbGxiYWNrVGFnIjogIkRJUkVDVCIsCiAgICAgICAgInN0cmF0ZWd5IjogewogICAgICAgICAgInR5cGUiOiAicmFuZG9tIgogICAgICAgIH0KICAgICAgfQogICAgXSwKICAgICJydWxlcyI6IFsKICAgICAgewogICAgICAgICJwb3J0IjogIjQ0MyIsCiAgICAgICAgInR5cGUiOiAiZmllbGQiLAogICAgICAgICJuZXR3b3JrIjogInVkcCIsCiAgICAgICAgImluYm91bmRUYWciOiBbCiAgICAgICAgICAiWEhUVFAtVExTIgogICAgICAgIF0sCiAgICAgICAgIm91dGJvdW5kVGFnIjogIkJMT0NLIgogICAgICB9LAogICAgICB7CiAgICAgICAgInR5cGUiOiAiZmllbGQiLAogICAgICAgICJwb3J0IjogIjI1IiwKICAgICAgICAibmV0d29yayI6ICJ0Y3AiLAogICAgICAgICJvdXRib3VuZFRhZyI6ICJCTE9DSyIKICAgICAgfSwKICAgICAgewogICAgICAgICJ0eXBlIjogImZpZWxkIiwKICAgICAgICAicHJvdG9jb2wiOiBbCiAgICAgICAgICAiYml0dG9ycmVudCIKICAgICAgICBdLAogICAgICAgICJvdXRib3VuZFRhZyI6ICJCTE9DSyIKICAgICAgfSwKICAgICAgewogICAgICAgICJpcCI6IFsKICAgICAgICAgICJnZW9pcDpwcml2YXRlIgogICAgICAgIF0sCiAgICAgICAgInR5cGUiOiAiZmllbGQiLAogICAgICAgICJvdXRib3VuZFRhZyI6ICJCTE9DSyIKICAgICAgfSwKICAgICAgewogICAgICAgICJ0eXBlIjogImZpZWxkIiwKICAgICAgICAiZG9tYWluIjogWwogICAgICAgICAgImdlb3NpdGU6cHJpdmF0ZSIKICAgICAgICBdLAogICAgICAgICJvdXRib3VuZFRhZyI6ICJCTE9DSyIKICAgICAgfSwKICAgICAgewogICAgICAgICJ0eXBlIjogImZpZWxkIiwKICAgICAgICAiZG9tYWluIjogWwogICAgICAgICAgImdlb3NpdGU6Y2F0ZWdvcnktYWRzLWFsbCIsCiAgICAgICAgICAiZG9tYWluOmFuYWx5dGljcy5nb29nbGUuY29tIiwKICAgICAgICAgICJkb21haW46YWRqdXN0Lm5ldC5pbiIsCiAgICAgICAgICAiZG9tYWluOmFtcGxpdHVkZS5jb20iLAogICAgICAgICAgImRvbWFpbjptZXRyaWthLnlhbmRleC5ydSIsCiAgICAgICAgICAiZG9tYWluOm15dHJhY2tlci5ydSIKICAgICAgICBdLAogICAgICAgICJvdXRib3VuZFRhZyI6ICJCTE9DSyIKICAgICAgfSwKICAgICAgewogICAgICAgICJ0eXBlIjogImZpZWxkIiwKICAgICAgICAiZG9tYWluIjogWwogICAgICAgICAgImRvbWFpbjpnZW1pbmkuZ29vZ2xlLmNvbSIsCiAgICAgICAgICAiZG9tYWluOmdlbWluaS5nb29nbGUiLAogICAgICAgICAgImRvbWFpbjpiYXJkLmdvb2dsZS5jb20iLAogICAgICAgICAgImRvbWFpbjphaXN0dWRpby5nb29nbGUuY29tIiwKICAgICAgICAgICJkb21haW46Z2VuZXJhdGl2ZWxhbmd1YWdlLmdvb2dsZWFwaXMuY29tIiwKICAgICAgICAgICJkb21haW46YWxrYWxpbWFrZXJzdWl0ZS1wYS5jbGllbnRzNi5nb29nbGUuY29tIiwKICAgICAgICAgICJkb21haW46Z2VtaW5pcGVyc29uYWxpemF0aW9uLXBhLmdvb2dsZWFwaXMuY29tIiwKICAgICAgICAgICJkb21haW46cHJvYWN0aXZlYmFja2VuZC1wYS5nb29nbGVhcGlzLmNvbSIsCiAgICAgICAgICAiZG9tYWluOmdlbGxlci1wYS5nb29nbGVhcGlzLmNvbSIsCiAgICAgICAgICAiZG9tYWluOm1ha2Vyc3VpdGUuZ29vZ2xlLmNvbSIsCiAgICAgICAgICAiZG9tYWluOm5vdGVib29rbG0uZ29vZ2xlLmNvbSIsCiAgICAgICAgICAiZG9tYWluOm5vdGVib29rbG0uZ29vZ2xlIiwKICAgICAgICAgICJkb21haW46YWkuZ29vZ2xlLmRldiIsCiAgICAgICAgICAiZG9tYWluOmRlZXBtaW5kLmdvb2dsZSIsCiAgICAgICAgICAiZG9tYWluOmxhYnMuZ29vZ2xlIgogICAgICAgIF0sCiAgICAgICAgImJhbGFuY2VyVGFnIjogImdvb2dsZS1iYWxhbmNlciIKICAgICAgfQogICAgXSwKICAgICJkb21haW5TdHJhdGVneSI6ICJJUElmTm9uTWF0Y2giCiAgfQp9" | base64 -d > /usr/share/goji-node/xray-node-profile.json
  cat > /usr/local/sbin/goji-panel <<'PYEOF'
#!/usr/bin/env python3
"""goji-panel - configure a Remnawave panel for the Goji XHTTP+TLS node over its REST API.

  goji-panel sync --url https://panel.example.com --domain node.example.com [options]

Creates (or reuses) the config profile, makes it the active profile of this node, and
creates or updates the host. Nothing is deleted. The API token is read from the
environment variable GOJI_PANEL_TOKEN (create it in the panel: Settings -> API tokens).
Endpoints and fields follow the Remnawave backend contract (checked against v3.4.4).
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
                raise ApiError(f"{method} {path}: HTTP {exc.code} - token rejected or lacks scope. {detail}")
            raise ApiError(f"{method} {path}: HTTP {exc.code} {detail}")
        except (urllib.error.URLError, OSError) as exc:
            raise ApiError(f"{method} {path}: {exc}")
        if not raw:
            return None
        try:
            return json.loads(raw)
        except ValueError:
            raise ApiError(f"{method} {path}: the answer is not JSON (is --url the panel address?)")

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
        log(f"[*] profile '{args.profile_name}': creating")
        if dry:
            prof = {"uuid": "(new)", "inbounds": [{"uuid": "(new)", "tag": tag}], "config": desired}
        else:
            prof = panel.call("POST", "/api/config-profiles", {"name": args.profile_name, "config": desired})["response"]
        log("[+] profile created")
    elif prof.get("config") == desired:
        log(f"[+] profile '{args.profile_name}': already up to date")
    elif args.overwrite_profile:
        log(f"[*] profile '{args.profile_name}': differs from the Goji profile, overwriting (--panel-overwrite-profile)")
        if not dry:
            prof = panel.call("PATCH", "/api/config-profiles", {"uuid": prof["uuid"], "config": desired})["response"]
        log("[+] profile updated")
    else:
        log(f"[!] profile '{args.profile_name}' exists and differs from the Goji profile; keeping it as is "
            "(use --panel-overwrite-profile to replace its config)")
    inbound = find_inbound(prof, tag)
    if inbound is None:
        raise ApiError(f"profile '{args.profile_name}' has no inbound with tag '{tag}'")
    live_cfg = prof.get("config") if isinstance(prof.get("config"), dict) else desired
    live_port = (live_cfg.get("inbounds") or [{}])[0].get("port")
    if live_port != args.xray_port:
        log(f"[!] the existing profile listens on port {live_port}, but nginx will proxy to {args.xray_port}: "
            "re-run with --xray-port or --panel-overwrite-profile")

    # ---- node
    node = None
    nodes = panel.get("/api/nodes")
    if args.node:
        node = next((n for n in nodes if args.node in (n["name"], n["uuid"])), None)
        if node is None:
            raise ApiError(f"node '{args.node}' not found in the panel")
    else:
        addrs = {a.lower() for a in args.node_address if a}
        cand = [n for n in nodes if n["address"].lower() in addrs]
        if len(cand) == 1:
            node = cand[0]
        elif len(cand) > 1:
            names = ", ".join(n["name"] for n in cand)
            raise ApiError(f"several nodes match this server ({names}); choose one with --panel-node")
    if node is None:
        log("[!] no node with this server's address found in the panel; the profile/host are ready, "
            "assign the profile to the node manually (or pass --panel-node NAME)")
    else:
        active = node["configProfile"]["activeConfigProfileUuid"]
        active_ib = {i["uuid"] for i in node["configProfile"]["activeInbounds"]}
        if active == prof["uuid"] and inbound["uuid"] in active_ib:
            log(f"[+] node '{node['name']}': profile already active")
        else:
            log(f"[*] node '{node['name']}': switching the active profile "
                f"(was {active or 'none'}) - Xray on the node will restart")
            if not dry:
                panel.call("PATCH", "/api/nodes", {"uuid": node["uuid"], "configProfile": {
                    "activeConfigProfileUuid": prof["uuid"], "activeInbounds": [inbound["uuid"]]}})
            log("[+] node profile switched")

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
        log(f"[*] host '{remark}': creating")
        if not dry:
            host = panel.call("POST", "/api/hosts", fields)["response"]
        log("[+] host created")
    else:
        changed = {k: v for k, v in fields.items()
                   if (sorted(host.get(k) or []) != v if k == "nodes" else host.get(k) != v)}
        if not changed:
            log(f"[+] host '{host['remark']}': already up to date")
        else:
            log(f"[*] host '{host['remark']}': updating {', '.join(sorted(changed))}")
            if not dry:
                panel.call("PATCH", "/api/hosts", {"uuid": host["uuid"], **fields})
            log("[+] host updated")

    # ---- squads (users only receive hosts of inbounds that are in their internal squad)
    if args.squad:
        squads = panel.get("/api/internal-squads")["internalSquads"]
        for name in args.squad:
            sq = next((s for s in squads if s["name"] == name), None)
            if sq is None:
                log(f"[!] internal squad '{name}' not found - skipped")
                continue
            have = [i["uuid"] for i in sq["inbounds"]]
            if inbound["uuid"] in have:
                log(f"[+] squad '{name}': inbound already included")
                continue
            log(f"[*] squad '{name}': adding the inbound (existing inbounds are kept)")
            if not dry:
                panel.call("PATCH", "/api/internal-squads", {"uuid": sq["uuid"], "inbounds": have + [inbound["uuid"]]})
            log("[+] squad updated")
    else:
        log("[i] no --panel-squad given: users get this host only after the inbound is added to an internal squad")
    if dry:
        log("[i] dry run: nothing was changed")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="goji-panel", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("sync", help="create/update profile, node assignment and host")
    s.add_argument("--url", required=True, help="panel address, e.g. https://panel.example.com")
    s.add_argument("--domain", required=True)
    s.add_argument("--xray-port", type=int, default=10443)
    s.add_argument("--path", default="/api/v2/telemetry/")
    s.add_argument("--node", default="", help="node name or uuid (default: match by --node-address)")
    s.add_argument("--node-address", action="append", default=[], help="address(es) the node is registered with")
    s.add_argument("--profile-name", default="Goji XHTTP-TLS")
    s.add_argument("--host-remark", default="")
    s.add_argument("--squad", action="append", default=[], help="internal squad name to add the inbound to (repeatable)")
    s.add_argument("--overwrite-profile", action="store_true")
    s.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)
    token = os.environ.get("GOJI_PANEL_TOKEN", "").strip()
    if not token:
        print("GOJI_PANEL_TOKEN is not set", file=sys.stderr)
        return 1
    args.domain = args.domain.lower()
    if not urllib.parse.urlparse(args.url).scheme in ("http", "https"):
        print("--url must start with http:// or https://", file=sys.stderr)
        return 1
    try:
        return sync(args, token)
    except ApiError as exc:
        print(f"[x] {exc}", file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError) as exc:
        print(f"[x] unexpected answer or local error: {exc!r}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
PYEOF
  chmod 755 /usr/local/sbin/goji-panel
}

panel_sync() {
  [[ -n "$PANEL_URL" ]] || return 0
  if [[ -z "$PANEL_TOKEN" ]]; then
    warn "panel step skipped: no API token (GOJI_PANEL_TOKEN). Later: GOJI_PANEL_TOKEN=... goji-panel sync --url $PANEL_URL --domain $DOMAIN"
    return 0
  fi
  command -v python3 >/dev/null || { warn "python3 is missing — panel step skipped"; return 0; }
  install_panel_tool
  local args=(sync --url "$PANEL_URL" --domain "$DOMAIN" --xray-port "$XRAY_PORT" --path "$XPATH"
              --profile-name "$PANEL_PROFILE" --node-address "$DOMAIN" --node-address "${MY_IP:-}" --node-address "${DNS_IP:-}")
  [[ -z "$PANEL_NODE" ]] || args+=(--node "$PANEL_NODE")
  [[ -z "$PANEL_HOST" ]] || args+=(--host-remark "$PANEL_HOST")
  [[ $PANEL_OVERWRITE -eq 0 ]] || args+=(--overwrite-profile)
  local sq
  for sq in "${PANEL_SQUADS[@]}"; do args+=(--squad "$sq"); done
  info "Configuring the Remnawave panel ($PANEL_URL)"
  if GOJI_PANEL_TOKEN="$PANEL_TOKEN" /usr/local/sbin/goji-panel "${args[@]}"; then
    ok "panel configured: profile, node and host"
  else
    warn "panel configuration failed — do it by hand (INSTALL.md) or fix the cause and run: bash install.sh --resume"
  fi
}

# helper for the post-install command; written by install_check_command below
install_check_command() {
  {
    echo '#!/usr/bin/env bash'
    declare -f gj_row goji_check
    echo 'goji_check "$@"'
  } > /usr/local/sbin/goji-node-check
  chmod 755 /usr/local/sbin/goji-node-check
}

if [[ $HARDEN -eq 1 ]]; then
  harden_system
  harden_ssh
  harden_ping
  if [[ $GUARD_ON -eq 1 ]]; then harden_guard; else info "Traffic Control not installed (use --traffic-control)"; fi
else
  info "Hardening skipped (--skip-hardening)"
fi
install_check_command
panel_sync

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
  warn "XHTTP profile is not active yet (nothing on 127.0.0.1:$XRAY_PORT)."
  echo "    Switch this node's profile in Remnawave to the XHTTP one"
  echo "    (inbound 127.0.0.1:$XRAY_PORT, xhttp, path $XPATH) and update the host."
  info "Waiting up to $WAIT s for the XHTTP profile..."
  for ((i = 0; i < WAIT; i += 5)); do
    ready && break
    sleep 5
  done
  if ! ready; then
    warn "XHTTP profile did not come up. The old profile keeps working; nginx TLS front is not enabled yet."
    echo "    After switching the profile run:  bash install.sh --resume   (status: goji-node-check)"
    exit 2
  fi
fi

# ---------------------------------------------------------------- nginx :443
info "Enabling TLS front"
# ssl_reject_handshake needs nginx >= 1.19.4; older nginx gets a catch-all that
# uses the same certificate and closes the connection (return 444).
NGINX_VER=$(nginx -v 2>&1 | sed -n 's#.*nginx/\([0-9.]*\).*#\1#p')
if [[ "$(printf '%s\n1.19.4\n' "$NGINX_VER" | sort -V | head -1)" == "1.19.4" ]]; then
  DEFAULT_SRV="    ssl_reject_handshake on;"
else
  warn "nginx $NGINX_VER is older than 1.19.4: using a catch-all server instead of ssl_reject_handshake"
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
ok "nginx is serving https://$DOMAIN"

# ---------------------------------------------------------------- self-test
code=$(curl -s -o /dev/null -w '%{http_code}' --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" || true)
[[ "$code" == "200" ]] && ok "Decoy site: HTTP 200" || warn "Decoy site returned HTTP $code"
if ss -Hltn "sport = :$XRAY_PORT" | grep -q .; then
  ok "Xray XHTTP is listening on 127.0.0.1:$XRAY_PORT"
else
  warn "Nothing listens on 127.0.0.1:$XRAY_PORT yet — check the node profile in Remnawave"
fi

cat <<EOF

Remnawave host for $DOMAIN:
  address/port : $DOMAIN / 443
  network      : xhttp      path: $XPATH      mode: auto
  security     : tls        sni : $DOMAIN     alpn: h2
  fingerprint  : firefox    flow: (empty)
EOF

echo
echo "Keep this SSH session open and verify a second login before closing it."
rc=0
goji_check || rc=$?
exit $rc
