#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

# shellcheck source=/dev/null
. "$APP_ROOT/deploy.env"

IFS= read -r DEPLOY_SUDO_PASSWORD || true
if [ -z "${DEPLOY_SUDO_PASSWORD:-}" ]; then
    echo "Missing sudo password on stdin." >&2
    exit 1
fi

sudo_cmd() {
    printf '%s\n' "$DEPLOY_SUDO_PASSWORD" | sudo -S -p '' "$@"
}

echo "Issuing or renewing the TLS certificate for $JELLYFIN_DOMAIN"
sudo_cmd docker compose -f "$APP_ROOT/docker-compose.yml" run --rm certbot \
    certonly \
    --webroot \
    --webroot-path /var/www/certbot \
    --keep-until-expiring \
    --agree-tos \
    --non-interactive \
    --email "$LETSENCRYPT_EMAIL" \
    --domain "$JELLYFIN_DOMAIN"

cp "$APP_ROOT/nginx/https.conf" "$APP_ROOT/nginx/active.conf"

echo "Reloading nginx with the HTTPS configuration"
sudo_cmd docker compose -f "$APP_ROOT/docker-compose.yml" up -d nginx
sudo_cmd docker compose -f "$APP_ROOT/docker-compose.yml" exec -T nginx nginx -s reload

echo "Installing the certificate renewal cron job"
cron_file=/etc/cron.d/jellyfin-certbot-renew

cron_body=$(cat <<EOF
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 3 * * * root /bin/sh '$APP_ROOT/scripts/renew-certificates.sh' >> '$APP_ROOT/logs/certbot-renew.log' 2>&1
EOF
)

printf '%s\n' "$cron_body" | sudo_cmd tee "$cron_file" >/dev/null
sudo_cmd chmod 644 "$cron_file"

echo "TLS finalization complete"
