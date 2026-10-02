#!/usr/bin/env bash
# XHTTP + TLS front for a Remnawave node: nginx (TLS, decoy site) -> Xray XHTTP.
#
# Usage:
#   bash install.sh [domain] [--email you@example.com] [--xray-port 10443]
#                            [--path /api/v2/telemetry/] [--wait 900]
#                            [--secret-key KEY] [--node-port 2222]
#                            [--panel-ip 1.2.3.4] [--skip-node]
#                            [--template random|analytics|blog|docs|saas]
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
    -h|--help)   sed -n '2,15p' "$0"; exit 0 ;;
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
