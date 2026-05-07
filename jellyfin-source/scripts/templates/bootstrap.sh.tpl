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

wait_for_container() {
    container_name=$1
    retries=${2:-60}
    count=0

    while [ "$count" -lt "$retries" ]; do
        if sudo_cmd docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null | grep -q '^true$'; then
            return 0
        fi

        count=$((count + 1))
        sleep 2
    done

    return 1
}

require_curl() {
    if ! command -v curl >/dev/null 2>&1; then
        echo "curl is required on the target host for qBittorrent bootstrap." >&2
        exit 1
    fi
}

qb_base_url() {
    printf 'http://127.0.0.1:%s' "$QBITTORRENT_WEBUI_PORT"
}

qb_referer() {
    printf 'http://127.0.0.1:%s/' "$QBITTORRENT_WEBUI_PORT"
}

qb_version() {
    cookie_file=$1
    curl -fsS -b "$cookie_file" --referer "$(qb_referer)" "$(qb_base_url)/api/v2/app/version" >/dev/null
}

qb_login() {
    username=$1
    password=$2
    cookie_file=$3

    rm -f "$cookie_file"
    login_body=$(curl -fsS -c "$cookie_file" --referer "$(qb_referer)" \
        --data-urlencode "username=$username" \
        --data-urlencode "password=$password" \
        "$(qb_base_url)/api/v2/auth/login")

    if [ "$login_body" != "Ok." ]; then
        return 1
    fi

    qb_version "$cookie_file"
}

qb_post() {
    cookie_file=$1
    api_path=$2
    shift 2

    curl -fsS -b "$cookie_file" --referer "$(qb_referer)" "$@" "$(qb_base_url)$api_path" >/dev/null
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

bootstrap_qbittorrent() {
    require_curl

    cookie_file="$APP_ROOT/.qb-cookie"
    temp_password=

    if qb_login "$QBITTORRENT_USERNAME" "$QBITTORRENT_PASSWORD" "$cookie_file"; then
        :
    else
        attempts=0
        while [ "$attempts" -lt 30 ]; do
            temp_password=$(sudo_cmd docker logs qbittorrent 2>&1 | sed -n 's/.*temporary password is provided for this session: //p' | tail -n 1)
            if [ -n "$temp_password" ]; then
                break
            fi

            attempts=$((attempts + 1))
            sleep 2
        done

        if [ -z "$temp_password" ]; then
            echo "Could not find the qBittorrent temporary password in container logs." >&2
            rm -f "$cookie_file"
            exit 1
        fi

        if ! qb_login admin "$temp_password" "$cookie_file"; then
            echo "Could not authenticate to qBittorrent with the temporary password." >&2
            rm -f "$cookie_file"
            exit 1
        fi
    fi

    preferences_json=$(printf '{"web_ui_username":"%s","web_ui_password":"%s","save_path":"/downloads"}' \
        "$(json_escape "$QBITTORRENT_USERNAME")" \
        "$(json_escape "$QBITTORRENT_PASSWORD")")

    qb_post "$cookie_file" /api/v2/app/setPreferences --data-urlencode "json=$preferences_json"
    qb_post "$cookie_file" /api/v2/torrents/createCategory \
        --data-urlencode "category=$QBITTORRENT_CATEGORY" \
        --data-urlencode "savePath=/downloads" || true

    if ! qb_login "$QBITTORRENT_USERNAME" "$QBITTORRENT_PASSWORD" "$cookie_file"; then
        echo "qBittorrent credentials did not persist after bootstrap." >&2
        rm -f "$cookie_file"
        exit 1
    fi

    rm -f "$cookie_file"
}

echo "Verifying docker availability"
sudo_cmd docker version >/dev/null
sudo_cmd docker compose version >/dev/null

echo "Preparing storage directories under $REMOTE_STORAGE_ROOT"
sudo_cmd mkdir -p \
    "$REMOTE_STORAGE_ROOT" \
    "$REMOTE_STORAGE_ROOT/jellyfin" \
    "$REMOTE_STORAGE_ROOT/jellyfin/config/data/plugins/configurations" \
    "$REMOTE_STORAGE_ROOT/jellyfin/cache" \
    "$REMOTE_STORAGE_ROOT/qbittorrent" \
    "$REMOTE_STORAGE_ROOT/qbittorrent/config" \
    "$REMOTE_STORAGE_ROOT/media" \
    "$REMOTE_STORAGE_ROOT/media/downloads" \
    "$REMOTE_STORAGE_ROOT/nginx" \
    "$REMOTE_STORAGE_ROOT/nginx/webroot" \
    "$REMOTE_STORAGE_ROOT/nginx/letsencrypt" \
    "$REMOTE_STORAGE_ROOT/search"

sudo_cmd chown "$DEPLOY_SSH_USER:$DEPLOY_SSH_USER" \
    "$REMOTE_STORAGE_ROOT" \
    "$REMOTE_STORAGE_ROOT/media/downloads"

sudo_cmd chown -R "$DEPLOY_SSH_USER:$DEPLOY_SSH_USER" \
    "$REMOTE_STORAGE_ROOT/jellyfin" \
    "$REMOTE_STORAGE_ROOT/qbittorrent" \
    "$REMOTE_STORAGE_ROOT/nginx" \
    "$REMOTE_STORAGE_ROOT/search"

if [ -n "$REMOTE_STORAGE_LINK" ]; then
    echo "Updating convenience symlink $REMOTE_STORAGE_LINK -> $REMOTE_STORAGE_ROOT"
    sudo_cmd ln -sfn "$REMOTE_STORAGE_ROOT" "$REMOTE_STORAGE_LINK"
    sudo_cmd chown -h "$DEPLOY_SSH_USER:$DEPLOY_SSH_USER" "$REMOTE_STORAGE_LINK"
fi

mkdir -p "$APP_ROOT/logs" "$APP_ROOT/nginx" "$APP_ROOT/scripts" "$APP_ROOT/artifacts"
chmod +x "$APP_ROOT"/scripts/*.sh

if [ "$PLUGIN_ENABLED" = "1" ]; then
    echo "Installing MyJellyfinPlugin into persistent storage"
    sudo_cmd mkdir -p "$REMOTE_STORAGE_ROOT/jellyfin/config/data/plugins/$PLUGIN_DIRECTORY"
    sudo_cmd cp "$APP_ROOT/artifacts/$PLUGIN_DLL_NAME" "$REMOTE_STORAGE_ROOT/jellyfin/config/data/plugins/$PLUGIN_DIRECTORY/$PLUGIN_DLL_NAME"
    sudo_cmd cp "$APP_ROOT/artifacts/MyJellyfinPlugin.xml" "$REMOTE_STORAGE_ROOT/jellyfin/config/data/plugins/configurations/MyJellyfinPlugin.xml"
    sudo_cmd chown -R "$DEPLOY_SSH_USER:$DEPLOY_SSH_USER" "$REMOTE_STORAGE_ROOT/jellyfin/config/data/plugins"
fi

if [ -f "$REMOTE_STORAGE_ROOT/nginx/letsencrypt/live/$JELLYFIN_DOMAIN/fullchain.pem" ]; then
    cp "$APP_ROOT/nginx/https.conf" "$APP_ROOT/nginx/active.conf"
else
    cp "$APP_ROOT/nginx/http.conf" "$APP_ROOT/nginx/active.conf"
fi

echo "Loading the custom Jellyfin image archive"
sudo_cmd docker load -i "$APP_ROOT/artifacts/custom-jellyfin.tar" >/dev/null
rm -f "$APP_ROOT/artifacts/custom-jellyfin.tar"

echo "Starting the deployment stack"
sudo_cmd docker compose -f "$APP_ROOT/docker-compose.yml" up -d --build torrent-search qbittorrent jellyfin nginx

wait_for_container qbittorrent 60 || {
    echo "qBittorrent did not reach the running state." >&2
    exit 1
}

wait_for_container jellyfin 60 || {
    echo "Jellyfin did not reach the running state." >&2
    exit 1
}

wait_for_container jellyfin-nginx 60 || {
    echo "Nginx did not reach the running state." >&2
    exit 1
}

echo "Bootstrapping qBittorrent credentials"
bootstrap_qbittorrent

echo "HTTP bootstrap complete"
