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
#
# Reinstalls Remnawave Node (docker, /opt/remnanode) asking for SECRET_KEY etc.
# Xray profile is managed by Remnawave: switch the node profile to the XHTTP one
# (listen 127.0.0.1:<xray-port>, security none) — the script waits for port 443
# to become free and then enables the TLS front.
set -euo pipefail

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

die()  { echo -e "\e[31m[x] $*\e[0m" >&2; exit 1; }
info() { echo -e "\e[36m[*] $*\e[0m"; }
ok()   { echo -e "\e[32m[+] $*\e[0m"; }
warn() { echo -e "\e[33m[!] $*\e[0m"; }

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
    -h|--help)   sed -n '2,17p' "$0"; exit 0 ;;
    -*)          die "unknown option: $1" ;;
    *)           DOMAIN="$1"; shift ;;
  esac
done

[[ $EUID -eq 0 ]] || die "run as root"
command -v apt-get >/dev/null || die "only Debian/Ubuntu (apt) is supported"
[[ "$XPATH" == /*/ ]] || die "--path must start and end with '/'"

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
  [[ -n "$PANEL_IP" ]] || ask PANEL_IP "Panel IP to allow on NODE_PORT (Enter = skip firewall rule)" ""
  if [[ -z "$EMAIL" ]]; then ask EMAIL "E-mail for Let's Encrypt (Enter = none)" ""; fi
fi

# ---------------------------------------------------------------- packages
info "Installing nginx and certbot"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nginx certbot curl ca-certificates iproute2 >/dev/null
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
echo "__TEMPLATES_B64__" | base64 -d | tar -xz -C "$TPL_DIR"
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

    # ICMP echo-request: rate-limited by default, dropped with --icmp-drop.
    # Other ICMP (destination-unreachable, time-exceeded, ICMPv6 ND) stays untouched,
    # so Path MTU Discovery and IPv6 keep working.
    local rf
    for rf in /etc/ufw/before.rules /etc/ufw/before6.rules; do
      [[ -f "$rf" ]] || continue
      [[ -f "$rf.goji-bak" ]] || cp -p "$rf" "$rf.goji-bak"
      sed -i '/--comment goji-icmp/d' "$rf"
      local chain=ufw-before-input itype="icmp --icmp-type echo-request"
      if [[ "$rf" == *6.rules ]]; then chain=ufw6-before-input; itype="icmpv6 --icmpv6-type echo-request"; fi
      local pat="^-A $chain -p $itype -j ACCEPT\$"
      local drop="-A $chain -p $itype -m comment --comment goji-icmp -j DROP"
      local lim="-A $chain -p $itype -m limit --limit 5/second --limit-burst 10 -m comment --comment goji-icmp -j ACCEPT"
      if [[ $ICMP_DROP -eq 1 ]]; then
        sed -i "/$pat/i\\$drop" "$rf"
      else
        sed -i -e "/$pat/i\\$lim" -e "/$pat/i\\$drop" "$rf"
      fi
    done

    if [[ $was_active -eq 1 ]]; then
      ufw reload >/dev/null || warn "ufw reload failed — check /etc/ufw/before.rules"
    else
      ufw --force enable >/dev/null || warn "ufw failed to enable"
    fi
    if ufw status | grep -q "Status: active"; then
      ok "ufw active (ssh: ${ssh_ports[*]}, 80, 443$([[ -n "$np" ]] && echo ", $np"))"
      [[ $ICMP_DROP -eq 1 ]] && ok "ICMP echo-request: dropped" || ok "ICMP echo-request: limited to 5/s"
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

if [[ $HARDEN -eq 1 ]]; then
  harden_system
else
  info "Hardening skipped (--skip-hardening)"
fi

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
  ready || die "XHTTP profile did not come up. Old profile keeps working; re-run after switching."
fi

# ---------------------------------------------------------------- nginx :443
info "Enabling TLS front"
cat > "$CONF" <<EOF
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    ssl_reject_handshake on;
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
