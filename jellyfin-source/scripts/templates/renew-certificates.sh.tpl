#!/bin/sh
set -eu

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

# shellcheck source=/dev/null
. "$APP_ROOT/deploy.env"

DOCKER_BIN=$(command -v docker)

cd "$APP_ROOT"
"$DOCKER_BIN" compose -f "$APP_ROOT/docker-compose.yml" run --rm certbot renew --webroot -w /var/www/certbot --quiet
"$DOCKER_BIN" compose -f "$APP_ROOT/docker-compose.yml" exec -T nginx nginx -s reload
