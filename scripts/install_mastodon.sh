#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ─── Logging ────────────────────────────────────────────────────────────────
LOG_FILE="/var/log/mastodon_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO  $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN  $*"; }
die()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR $*" >&2; exit 1; }

# ─── Root check ─────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run this script as root (sudo bash $0)"

# ─── Versions ───────────────────────────────────────────────────────────────
MASTODON_BRANCH="v4.3.2"
RUBY_VERSION="3.3.4"
NODE_MAJOR="20"

# ─── Interactive input ───────────────────────────────────────────────────────
prompt_domain() {
    while true; do
        read -rp "Enter the domain name for your Mastodon instance (e.g. mastodon.example.com): " DOMAIN
        [[ "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]] \
            && break || warn "Invalid domain. Try again."
    done
}

prompt_ssh_key() {
    while true; do
        read -rp "Paste your public SSH key: " SSH_PUB_KEY
        [[ "$SSH_PUB_KEY" =~ ^(ssh-(rsa|ed25519|ecdsa)|ecdsa-sha2-nistp(256|384|521))\ [A-Za-z0-9+/=]+ ]] \
            && break || warn "Invalid SSH public key format. Try again."
    done
}

prompt_ssh_port() {
    while true; do
        read -rp "Enter desired SSH port [default: 2222]: " SSH_PORT
        SSH_PORT="${SSH_PORT:-2222}"
        [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1024 && SSH_PORT <= 65535 )) \
            && break || warn "Port must be 1024–65535. Try again."
    done
}

prompt_email() {
    while true; do
        read -rp "Enter admin e-mail (used for Let's Encrypt + Mastodon admin): " ADMIN_EMAIL
        [[ "$ADMIN_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]] \
            && break || warn "Invalid e-mail. Try again."
    done
}

log "=== Mastodon Automated Installer ==="
prompt_domain
prompt_ssh_key
prompt_ssh_port
prompt_email

log "Domain : $DOMAIN"
log "SSH port: $SSH_PORT"
log "Admin e-mail: $ADMIN_EMAIL"

# ─── System update ───────────────────────────────────────────────────────────
log "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y --no-install-recommends \
    curl wget gnupg2 ca-certificates lsb-release \
    apt-transport-https software-properties-common \
    ufw fail2ban unzip git build-essential \
    imagemagick ffmpeg libpq-dev libxml2-dev libxslt1-dev \
    libprotobuf-dev protobuf-compiler pkg-config \
    libidn11-dev libicu-dev libjemalloc-dev \
    zlib1g-dev libssl-dev libreadline-dev \
    autoconf bison libncurses5-dev libffi-dev libgdbm-dev \
    redis-server redis-tools

# ─── PostgreSQL ───────────────────────────────────────────────────────────────
log "Installing PostgreSQL..."
if ! command -v psql &>/dev/null; then
    curl -fsSL "https://www.postgresql.org/media/keys/ACCC4CF8.asc" \
        | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg
    echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] \
https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list
    apt-get update -y
    apt-get install -y postgresql postgresql-contrib
fi

systemctl enable --now postgresql
PG_VERSION=$(pg_lsclusters -h | awk '{print $1}' | head -1)
log "PostgreSQL version: $PG_VERSION"

# ─── Node.js ─────────────────────────────────────────────────────────────────
log "Installing Node.js $NODE_MAJOR..."
if ! node --version 2>/dev/null | grep -q "^v${NODE_MAJOR}\."; then
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    apt-get install -y nodejs
fi

# ─── Yarn ────────────────────────────────────────────────────────────────────
log "Installing Yarn..."
if ! command -v yarn &>/dev/null; then
    npm install -g yarn
fi

# ─── rbenv + Ruby ─────────────────────────────────────────────────────────────
log "Installing rbenv and Ruby $RUBY_VERSION for mastodon user..."

# ─── Mastodon system user ─────────────────────────────────────────────────────
log "Creating mastodon system user..."
if ! id mastodon &>/dev/null; then
    adduser --disabled-password --gecos "" mastodon
fi

# Install rbenv as mastodon user
sudo -u mastodon bash -lc '
    set -euo pipefail
    export RBENV_ROOT="$HOME/.rbenv"
    if [ ! -d "$RBENV_ROOT" ]; then
        git clone https://github.com/rbenv/rbenv.git "$RBENV_ROOT"
        git clone https://github.com/rbenv/ruby-build.git "$RBENV_ROOT/plugins/ruby-build"
    fi
    grep -qxF "export PATH=\"\$HOME/.rbenv/bin:\$PATH\"" ~/.bashrc \
        || echo "export PATH=\"\$HOME/.rbenv/bin:\$PATH\"" >> ~/.bashrc
    grep -qxF "eval \"\$(rbenv init -)\"" ~/.bashrc \
        || echo "eval \"\$(rbenv init -)\"" >> ~/.bashrc
    export PATH="$HOME/.rbenv/bin:$PATH"
    eval "$(rbenv init -)"
    if ! rbenv versions --bare | grep -qx "'"$RUBY_VERSION"'"; then
        RUBY_CONFIGURE_OPTS="--with-jemalloc" rbenv install "'"$RUBY_VERSION"'"
    fi
    rbenv global "'"$RUBY_VERSION"'"
' || die "Ruby installation failed"

# ─── Nginx ───────────────────────────────────────────────────────────────────
log "Installing Nginx..."
apt-get install -y nginx
systemctl enable nginx

# ─── Certbot ─────────────────────────────────────────────────────────────────
log "Installing Certbot..."
snap install --classic certbot 2>/dev/null || apt-get install -y certbot python3-certbot-nginx
ln -sf /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true

# ─── PostgreSQL database & role ──────────────────────────────────────────────
log "Configuring PostgreSQL database..."
DB_PASS=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)

sudo -u postgres psql -c "SELECT 1 FROM pg_roles WHERE rolname='mastodon'" \
    | grep -q 1 || sudo -u postgres psql -c "CREATE USER mastodon CREATEDB;"

sudo -u postgres psql -c "SELECT 1 FROM pg_database WHERE datname='mastodon_production'" \
    | grep -q 1 \
    || sudo -u postgres createdb -O mastodon mastodon_production

# ─── Clone Mastodon ──────────────────────────────────────────────────────────
log "Cloning Mastodon $MASTODON_BRANCH..."
MASTO_HOME="/home/mastodon"
MASTO_DIR="$MASTO_HOME/live"

if [ ! -d "$MASTO_DIR/.git" ]; then
    sudo -u mastodon git clone https://github.com/mastodon/mastodon.git \
        --branch "$MASTODON_BRANCH" --depth 1 "$MASTO_DIR"
else
    log "Mastodon already cloned, skipping."
fi

# ─── Install gems & node packages ────────────────────────────────────────────
log "Installing Ruby gems and Node packages..."
sudo -u mastodon bash -lc "
    set -euo pipefail
    export PATH=\"\$HOME/.rbenv/bin:\$PATH\"
    eval \"\$(rbenv init -)\"
    cd $MASTO_DIR
    bundle config deployment 'true'
    bundle config without 'development test'
    bundle install -j\$(nproc)
    yarn install --pure-lockfile
"

# ─── .env.production ─────────────────────────────────────────────────────────
log "Generating .env.production..."
SECRET_KEY_BASE=$(sudo -u mastodon bash -lc "
    export PATH=\"\$HOME/.rbenv/bin:\$PATH\"
    eval \"\$(rbenv init -)\"
    cd $MASTO_DIR && RAILS_ENV=production bundle exec rake secret
")
OTP_SECRET=$(sudo -u mastodon bash -lc "
    export PATH=\"\$HOME/.rbenv/bin:\$PATH\"
    eval \"\$(rbenv init -)\"
    cd $MASTO_DIR && RAILS_ENV=production bundle exec rake secret
")
VAPID_KEYS=$(sudo -u mastodon bash -lc "
    export PATH=\"\$HOME/.rbenv/bin:\$PATH\"
    eval \"\$(rbenv init -)\"
    cd $MASTO_DIR && RAILS_ENV=production bundle exec rake mastodon:webpush:generate_vapid_key
")
VAPID_PRIVATE=$(echo "$VAPID_KEYS" | grep VAPID_PRIVATE | cut -d= -f2)
VAPID_PUBLIC=$(echo "$VAPID_KEYS"  | grep VAPID_PUBLIC  | cut -d= -f2)

cat > "$MASTO_DIR/.env.production" <<ENVEOF
# Generated by install_mastodon.sh
LOCAL_DOMAIN=$DOMAIN
SINGLE_USER_MODE=false
SECRET_KEY_BASE=$SECRET_KEY_BASE
OTP_SECRET=$OTP_SECRET
VAPID_PRIVATE_KEY=$VAPID_PRIVATE
VAPID_PUBLIC_KEY=$VAPID_PUBLIC

DB_HOST=/var/run/postgresql
DB_USER=mastodon
DB_NAME=mastodon_production
DB_PORT=5432

REDIS_HOST=127.0.0.1
REDIS_PORT=6379

SMTP_SERVER=localhost
SMTP_PORT=587
SMTP_FROM_ADDRESS=notifications@$DOMAIN

RAILS_ENV=production
RAILS_SERVE_STATIC_FILES=false
RAILS_LOG_TO_STDOUT=true
NODE_ENV=production
ENVEOF

chown mastodon:mastodon "$MASTO_DIR/.env.production"
chmod 640 "$MASTO_DIR/.env.production"

# ─── Database setup ───────────────────────────────────────────────────────────
log "Setting up database..."
sudo -u mastodon bash -lc "
    export PATH=\"\$HOME/.rbenv/bin:\$PATH\"
    eval \"\$(rbenv init -)\"
    cd $MASTO_DIR
    RAILS_ENV=production bundle exec rails db:setup
"

# ─── Asset precompilation ─────────────────────────────────────────────────────
log "Precompiling assets..."
sudo -u mastodon bash -lc "
    export PATH=\"\$HOME/.rbenv/bin:\$PATH\"
    eval \"\$(rbenv init -)\"
    cd $MASTO_DIR
    RAILS_ENV=production bundle exec rails assets:precompile
"

# ─── Systemd services ─────────────────────────────────────────────────────────
log "Installing systemd services..."

cat > /etc/systemd/system/mastodon-web.service <<'SVCEOF'
[Unit]
Description=mastodon-web
After=network.target

[Service]
Type=simple
User=mastodon
WorkingDirectory=/home/mastodon/live
Environment="RAILS_ENV=production"
Environment="PORT=3000"
ExecStart=/home/mastodon/.rbenv/shims/bundle exec puma -C config/puma.rb
ExecReload=/bin/kill -SIGUSR1 $MAINPID
TimeoutSec=15
Restart=always
SyslogIdentifier=mastodon-web

[Install]
WantedBy=multi-user.target
SVCEOF

cat > /etc/systemd/system/mastodon-streaming.service <<'SVCEOF'
[Unit]
Description=mastodon-streaming
After=network.target

[Service]
Type=simple
User=mastodon
WorkingDirectory=/home/mastodon/live
Environment="NODE_ENV=production"
Environment="PORT=4000"
ExecStart=/usr/bin/node ./streaming
TimeoutSec=15
Restart=always
SyslogIdentifier=mastodon-streaming

[Install]
WantedBy=multi-user.target
SVCEOF

cat > /etc/systemd/system/mastodon-sidekiq.service <<'SVCEOF'
[Unit]
Description=mastodon-sidekiq
After=network.target

[Service]
Type=simple
User=mastodon
WorkingDirectory=/home/mastodon/live
Environment="RAILS_ENV=production"
Environment="DB_POOL=25"
ExecStart=/home/mastodon/.rbenv/shims/bundle exec sidekiq -c 25
TimeoutSec=15
Restart=always
SyslogIdentifier=mastodon-sidekiq

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable mastodon-web mastodon-streaming mastodon-sidekiq
systemctl start  mastodon-web mastodon-streaming mastodon-sidekiq

# ─── Nginx configuration ──────────────────────────────────────────────────────
log "Configuring Nginx..."

cat > /etc/nginx/sites-available/mastodon <<NGXEOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

upstream backend {
    server 127.0.0.1:3000 fail_timeout=0;
}

upstream streaming {
    server 127.0.0.1:4000 fail_timeout=0;
}

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_session_timeout 1d;
    ssl_session_cache   shared:MozSSL:10m;
    ssl_session_tickets off;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;
    add_header Strict-Transport-Security "max-age=63072000" always;

    keepalive_timeout   70;
    sendfile            on;
    client_max_body_size 99m;

    root /home/mastodon/live/public;

    gzip on;
    gzip_disable "msie6";
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript application/rss+xml application/atom+xml image/svg+xml;

    location / {
        try_files \$uri @proxy;
    }

    location ~ ^/(emoji|packs|system/accounts/avatars|system/media_attachments/files) {
        add_header Cache-Control "public, max-age=31536000, immutable";
        add_header Strict-Transport-Security "max-age=63072000" always;
        try_files \$uri @proxy;
    }

    location /sw.js {
        add_header Cache-Control "public, max-age=604800, must-revalidate";
        add_header Strict-Transport-Security "max-age=63072000" always;
        try_files \$uri @proxy;
    }

    location @proxy {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Proxy "";
        proxy_pass_header Server;
        proxy_pass http://backend;
        proxy_buffering on;
        proxy_redirect off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        tcp_nodelay on;
    }

    location /api/v1/streaming {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Proxy "";
        proxy_pass http://streaming;
        proxy_buffering off;
        proxy_redirect off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        tcp_nodelay on;
    }

    error_page 500 501 502 503 504 /500.html;
}
NGXEOF

ln -sf /etc/nginx/sites-available/mastodon /etc/nginx/sites-enabled/mastodon
rm -f /etc/nginx/sites-enabled/default
nginx -t

# ─── SSL certificate ─────────────────────────────────────────────────────────
log "Obtaining Let's Encrypt certificate..."
systemctl stop nginx
certbot certonly --standalone \
    --non-interactive \
    --agree-tos \
    --email "$ADMIN_EMAIL" \
    -d "$DOMAIN"
systemctl start nginx

# ─── SSH hardening ────────────────────────────────────────────────────────────
log "Configuring SSH..."
MASTO_SSH_DIR="$MASTO_HOME/.ssh"
mkdir -p "$MASTO_SSH_DIR"
chmod 700 "$MASTO_SSH_DIR"

# Add key for root and mastodon user
ROOT_SSH_DIR="/root/.ssh"
mkdir -p "$ROOT_SSH_DIR"
chmod 700 "$ROOT_SSH_DIR"
grep -qxF "$SSH_PUB_KEY" "$ROOT_SSH_DIR/authorized_keys" 2>/dev/null \
    || echo "$SSH_PUB_KEY" >> "$ROOT_SSH_DIR/authorized_keys"
chmod 600 "$ROOT_SSH_DIR/authorized_keys"

grep -qxF "$SSH_PUB_KEY" "$MASTO_SSH_DIR/authorized_keys" 2>/dev/null \
    || echo "$SSH_PUB_KEY" >> "$MASTO_SSH_DIR/authorized_keys"
chown -R mastodon:mastodon "$MASTO_SSH_DIR"
chmod 600 "$MASTO_SSH_DIR/authorized_keys"

SSHD_CONF="/etc/ssh/sshd_config"
cp "$SSHD_CONF" "${SSHD_CONF}.bak.$(date +%s)"

sed -i "s/^#*Port .*/Port $SSH_PORT/"                       "$SSHD_CONF"
sed -i "s/^#*PasswordAuthentication .*/PasswordAuthentication no/" "$SSHD_CONF"
sed -i "s/^#*PermitRootLogin .*/PermitRootLogin prohibit-password/" "$SSHD_CONF"
sed -i "s/^#*PubkeyAuthentication .*/PubkeyAuthentication yes/"     "$SSHD_CONF"
sed -i "s/^#*ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/" "$SSHD_CONF"
grep -q "^AuthorizedKeysFile" "$SSHD_CONF" \
    || echo "AuthorizedKeysFile .ssh/authorized_keys" >> "$SSHD_CONF"

sshd -t || die "SSHD config test failed — aborting SSH changes"
systemctl restart sshd

# ─── UFW firewall ─────────────────────────────────────────────────────────────
log "Configuring UFW firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# ─── Fail2ban ─────────────────────────────────────────────────────────────────
log "Enabling fail2ban..."
systemctl enable --now fail2ban

# ─── Redis hardening ─────────────────────────────────────────────────────────
log "Configuring Redis..."
sed -i 's/^# *bind 127.0.0.1/bind 127.0.0.1/' /etc/redis/redis.conf
systemctl restart redis-server

# ─── Mastodon admin account ──────────────────────────────────────────────────
log "Creating Mastodon admin account..."
ADMIN_USER="admin"
ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

sudo -u mastodon bash -lc "
    export PATH=\"\$HOME/.rbenv/bin:\$PATH\"
    eval \"\$(rbenv init -)\"
    cd $MASTO_DIR
    RAILS_ENV=production bundle exec tootctl accounts create \
        '$ADMIN_USER' \
        --email '$ADMIN_EMAIL' \
        --confirmed \
        --role Owner \
        --password '$ADMIN_PASS' 2>/dev/null || true
    RAILS_ENV=production bundle exec tootctl accounts modify \
        '$ADMIN_USER' --role Owner 2>/dev/null || true
"

# ─── Certbot renewal cron ─────────────────────────────────────────────────────
log "Setting up certbot auto-renewal..."
if ! crontab -l 2>/dev/null | grep -q certbot; then
    (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
fi

# ─── Final output ─────────────────────────────────────────────────────────────
log "=== Installation complete ==="
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           Mastodon Installation Summary                     ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Domain        : https://$DOMAIN"
echo "║  SSH port      : $SSH_PORT"
echo "║  Admin user    : $ADMIN_USER"
echo "║  Admin email   : $ADMIN_EMAIL"
echo "║  Admin password: $ADMIN_PASS"
echo "║  Log file      : $LOG_FILE"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
warn "SAVE THE ADMIN PASSWORD ABOVE — it will not be shown again."
echo ""
log "Verify services: systemctl status mastodon-web mastodon-streaming mastodon-sidekiq"
