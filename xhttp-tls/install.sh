#!/usr/bin/env bash
# XHTTP + TLS front for a Remnawave node: nginx (TLS, decoy site) -> Xray XHTTP.
#
# Usage:
#   bash install.sh [domain] [--email you@example.com] [--xray-port 10443]
#                            [--path /api/v2/telemetry/] [--wait 900]
#                            [--secret-key KEY] [--node-port 2222]
#                            [--panel-ip 1.2.3.4] [--skip-node]
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
NODE_DIR=/opt/remnanode

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
    -h|--help)   sed -n '2,14p' "$0"; exit 0 ;;
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
info "Deploying decoy site to $WEBROOT"
mkdir -p "$WEBROOT" "$ACME"
echo "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" | base64 -d | tar -xz -C "$WEBROOT"
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
  (cd "$NODE_DIR" && docker compose pull -q && docker compose up -d) >/dev/null

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

# ---------------------------------------------------------------- wait for :443
port_busy() { ss -Hltn "sport = :443" | grep -q .; }
if port_busy && ! ss -Hltnp "sport = :443" | grep -q nginx; then
  warn "Port 443 is still used by Xray (Vision)."
  echo "    Now switch this node's profile in Remnawave to the XHTTP one"
  echo "    (inbound 127.0.0.1:$XRAY_PORT, xhttp, path $XPATH) and update the host."
  info "Waiting up to $WAIT s for port 443 to be released..."
  for ((i = 0; i < WAIT; i += 5)); do
    port_busy || break
    sleep 5
  done
  port_busy && die "443 is still busy. Re-run the script after switching the profile."
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
