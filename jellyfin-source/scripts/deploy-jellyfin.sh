#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(cd -- "$PROJECT_ROOT/.." && pwd)
TEMPLATE_ROOT="$SCRIPT_DIR/templates"

ENV_FILE=${DEPLOY_ENV_FILE:-"$SCRIPT_DIR/deploy.env"}
SKIP_PLUGIN=0
ENABLE_DLNA_OVERRIDE=
PROBE_TIMEOUT_SECONDS=${PROBE_TIMEOUT_SECONDS:-900}

usage() {
    cat <<'EOF'
Usage: ./deploy-jellyfin.sh [options]

Options:
  --env-file PATH          Load a deploy env file. Defaults to ./deploy.env.
  --skip-plugin            Deploy the stack without building/installing MyJellyfinPlugin.
  --enable-dlna            Publish Jellyfin DLNA discovery ports.
  --probe-timeout SECONDS  Seconds to wait for the HTTP DNS probe. Default: 900.
  -h, --help               Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --env-file)
            ENV_FILE=${2:?--env-file requires a path}
            shift 2
            ;;
        --skip-plugin)
            SKIP_PLUGIN=1
            shift
            ;;
        --enable-dlna)
            ENABLE_DLNA_OVERRIDE=true
            shift
            ;;
        --probe-timeout)
            PROBE_TIMEOUT_SECONDS=${2:?--probe-timeout requires seconds}
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

trim() {
    local value=$1
    value=${value//$'\r'/}
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

load_env_file() {
    local path=$1
    [ -f "$path" ] || return 0

    local line name value
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(trim "$line")
        [ -n "$line" ] || continue
        case "$line" in \#*) continue ;; esac
        case "$line" in *=*) ;; *) continue ;; esac

        name=$(trim "${line%%=*}")
        value=$(trim "${line#*=}")
        [ -n "$name" ] || continue

        case "$value" in
            \"*\") value=${value#\"}; value=${value%\"} ;;
            \'*\') value=${value#\'}; value=${value%\'} ;;
        esac

        export "$name=$value"
    done < "$path"
}

required() {
    local name=$1
    local value=${2:-}
    if [ -z "$(trim "$value")" ]; then
        echo "Missing required setting: $name" >&2
        exit 1
    fi
}

bool_value() {
    local value=${1:-}
    local default=${2:-false}
    value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
    case "$value" in
        1|true|yes|on) printf true ;;
        0|false|no|off) printf false ;;
        '') printf '%s' "$default" ;;
        *) echo "Could not parse boolean value: $1" >&2; exit 1 ;;
    esac
}

shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\"'\"'/g")"
}

xml_escape() {
    local value=${1:-}
    value=${value//&/&amp;}
    value=${value//</&lt;}
    value=${value//>/&gt;}
    value=${value//\"/&quot;}
    value=${value//\'/&apos;}
    printf '%s' "$value"
}

random_secret() {
    local length=${1:-32}
    local value=
    if command -v openssl >/dev/null 2>&1; then
        value=$(openssl rand -hex "$(((length + 1) / 2))" | cut -c "1-$length")
    else
        value=$(od -An -N "$(((length + 1) / 2))" -tx1 /dev/urandom | tr -d ' \n' | cut -c "1-$length")
    fi
    if [ "${#value}" -lt "$length" ]; then
        echo "Could not generate a random qBittorrent password." >&2
        exit 1
    fi
    printf '%s' "$value"
}

run() {
    printf '>>' >&2
    printf ' %q' "$@" >&2
    printf '\n' >&2
    "$@"
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

resolve_remote_path() {
    local path=$1
    local remote_home=$2
    path=$(trim "$path")
    case "$path" in
        "~") printf '%s' "$remote_home" ;;
        "~/"*) printf '%s/%s' "${remote_home%/}" "${path#~/}" ;;
        /*) printf '%s' "$path" ;;
        *) printf '%s/%s' "${remote_home%/}" "${path#./}" ;;
    esac
}

assert_no_whitespace_path() {
    local name=$1
    local value=$2
    if printf '%s' "$value" | grep -q '[[:space:]]'; then
        echo "$name cannot contain whitespace in this deployment flow: $value" >&2
        exit 1
    fi
}

docker_platform_for_arch() {
    case "$1" in
        x86_64|amd64) printf 'linux/amd64' ;;
        aarch64|arm64) printf 'linux/arm64' ;;
        *) echo "Unsupported remote architecture: $1. Only amd64 and arm64 are supported." >&2; exit 1 ;;
    esac
}

render_template() {
    local input=$1
    local output=$2
    local content
    content=$(<"$input")
    content=${content//$'\r'/}
    content=${content//__CUSTOM_IMAGE__/$CUSTOM_IMAGE}
    content=${content//__JELLYFIN_DOMAIN__/$JELLYFIN_DOMAIN}
    content=${content//__JELLYFIN_EXTRA_PORTS_BLOCK__/$JELLYFIN_EXTRA_PORTS_BLOCK}
    content=${content//__JELLYFIN_PUBLISHED_URL__/$JELLYFIN_PUBLISHED_URL}
    content=${content//__PUID__/$REMOTE_UID}
    content=${content//__PGID__/$REMOTE_GID}
    content=${content//__QBITTORRENT_PASSWORD__/$QBITTORRENT_PASSWORD}
    content=${content//__QBITTORRENT_TORRENT_PORT__/$QBITTORRENT_TORRENT_PORT}
    content=${content//__QBITTORRENT_USERNAME__/$QBITTORRENT_USERNAME}
    content=${content//__QBITTORRENT_WEBUI_PORT__/$QBITTORRENT_WEBUI_PORT}
    content=${content//__REMOTE_STORAGE_ROOT__/$RESOLVED_REMOTE_STORAGE_ROOT}
    content=${content//__TZ__/$TZ}
    printf '%s\n' "$content" > "$output"
}

copy_text_lf() {
    local input=$1
    local output=$2
    local content
    content=$(<"$input")
    content=${content//$'\r'/}
    printf '%s\n' "$content" > "$output"
}

render_plugin_config() {
    local input=$1
    local output=$2
    local escaped_user escaped_password content
    escaped_user=$(xml_escape "$QBITTORRENT_USERNAME")
    escaped_password=$(xml_escape "$QBITTORRENT_PASSWORD")
    content=$(<"$input")
    content=${content//$'\r'/}
    content=${content//__QBITTORRENT_USERNAME__/$escaped_user}
    content=${content//__QBITTORRENT_PASSWORD__/$escaped_password}
    content=${content//__QBITTORRENT_WEBUI_PORT__/$QBITTORRENT_WEBUI_PORT}
    printf '%s\n' "$content" > "$output"
}

wait_for_probe() {
    local url=$1
    local timeout=$2
    local deadline
    deadline=$((SECONDS + timeout))

    while [ "$SECONDS" -lt "$deadline" ]; do
        if curl -fsS --max-time 10 "$url" >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
    done

    echo "Timed out waiting for $url to return HTTP 200. Create the Cloudflare record for $JELLYFIN_DOMAIN and make sure port 80 reaches this host." >&2
    exit 1
}

build_plugin_artifact() {
    local project_path=$1
    local configuration=Release
    local plugin_root plugin_name output_root assembly_info version

    run dotnet build "$project_path" -c "$configuration"

    plugin_root=$(cd -- "$(dirname -- "$project_path")" && pwd)
    plugin_name=$(basename "$project_path" .csproj)
    output_root="$plugin_root/bin/$configuration"
    PLUGIN_DLL_PATH=$(find "$output_root" -type f -name "$plugin_name.dll" -printf '%T@ %p\n' | sort -nr | head -n 1 | cut -d' ' -f2-)
    if [ -z "$PLUGIN_DLL_PATH" ]; then
        echo "Built plugin assembly not found under $output_root" >&2
        exit 1
    fi

    assembly_info=$(find "$plugin_root/obj/$configuration" -type f -name "$plugin_name.AssemblyInfo.cs" 2>/dev/null | head -n 1 || true)
    version=
    if [ -n "$assembly_info" ]; then
        version=$(sed -n 's/.*AssemblyVersionAttribute("\([^"]*\)").*/\1/p' "$assembly_info" | head -n 1)
    fi
    PLUGIN_VERSION=${version:-1.0.0.0}
    PLUGIN_DLL_NAME=$(basename "$PLUGIN_DLL_PATH")
    PLUGIN_DIRECTORY="${plugin_name}_${PLUGIN_VERSION}"
}

load_env_file "$ENV_FILE"

DEPLOY_SSH_PORT=${DEPLOY_SSH_PORT:-22}
REMOTE_APP_ROOT=${REMOTE_APP_ROOT:-'~/jellyfin-app'}
TZ=${TZ:-UTC}
QBITTORRENT_USERNAME=${QBITTORRENT_USERNAME:-jellyfin}
QBITTORRENT_WEBUI_PORT=${QBITTORRENT_WEBUI_PORT:-8080}
QBITTORRENT_TORRENT_PORT=${QBITTORRENT_TORRENT_PORT:-6881}
ENABLE_DLNA=$(bool_value "${ENABLE_DLNA_OVERRIDE:-${ENABLE_DLNA:-false}}" false)

required DEPLOY_SSH_HOST "${DEPLOY_SSH_HOST:-}"
required DEPLOY_SSH_USER "${DEPLOY_SSH_USER:-}"
required JELLYFIN_DOMAIN "${JELLYFIN_DOMAIN:-}"
required LETSENCRYPT_EMAIL "${LETSENCRYPT_EMAIL:-}"
required REMOTE_STORAGE_ROOT "${REMOTE_STORAGE_ROOT:-}"

JELLYFIN_PUBLISHED_URL=${JELLYFIN_PUBLISHED_URL:-https://$JELLYFIN_DOMAIN}
QBITTORRENT_PASSWORD=${QBITTORRENT_PASSWORD:-$(random_secret 32)}

if [ -z "${DEPLOY_SUDO_PASSWORD:-}" ]; then
    if [ -n "${DEPLOY_SUDO_PASSWORD_FILE:-}" ]; then
        if [ ! -f "$DEPLOY_SUDO_PASSWORD_FILE" ]; then
            echo "Sudo password file not found: $DEPLOY_SUDO_PASSWORD_FILE" >&2
            exit 1
        fi
        DEPLOY_SUDO_PASSWORD=$(tr -d '\r\n' < "$DEPLOY_SUDO_PASSWORD_FILE")
    else
        read -r -s -p "Enter the remote sudo password: " DEPLOY_SUDO_PASSWORD
        printf '\n'
    fi
fi

required DEPLOY_SUDO_PASSWORD "$DEPLOY_SUDO_PASSWORD"

require_command ssh
require_command scp
require_command tar
require_command docker
require_command dotnet
require_command curl
docker buildx version >/dev/null

PLUGIN_PROJECT_PATH="$REPO_ROOT/MyJellyfinPlugin/MyJellyfinPlugin.csproj"
TORRENT_SEARCH_SOURCE="$REPO_ROOT/Torrent-Search-API"

if [ ! -d "$TORRENT_SEARCH_SOURCE" ]; then
    echo "Torrent-Search-API source not found: $TORRENT_SEARCH_SOURCE" >&2
    exit 1
fi

REMOTE_FACTS=$(run ssh -p "$DEPLOY_SSH_PORT" "$DEPLOY_SSH_USER@$DEPLOY_SSH_HOST" 'printf '"'"'%s|%s|%s|%s'"'"' "$HOME" "$(id -u)" "$(id -g)" "$(uname -m)"')
IFS='|' read -r REMOTE_HOME REMOTE_UID REMOTE_GID REMOTE_ARCHITECTURE <<EOF
$REMOTE_FACTS
EOF

RESOLVED_REMOTE_APP_ROOT=$(resolve_remote_path "$REMOTE_APP_ROOT" "$REMOTE_HOME")
RESOLVED_REMOTE_STORAGE_ROOT=$(resolve_remote_path "$REMOTE_STORAGE_ROOT" "$REMOTE_HOME")
RESOLVED_REMOTE_STORAGE_LINK=
if [ -n "${REMOTE_STORAGE_LINK:-}" ]; then
    RESOLVED_REMOTE_STORAGE_LINK=$(resolve_remote_path "$REMOTE_STORAGE_LINK" "$REMOTE_HOME")
fi

assert_no_whitespace_path REMOTE_APP_ROOT "$RESOLVED_REMOTE_APP_ROOT"
assert_no_whitespace_path REMOTE_STORAGE_ROOT "$RESOLVED_REMOTE_STORAGE_ROOT"
if [ -n "$RESOLVED_REMOTE_STORAGE_LINK" ]; then
    assert_no_whitespace_path REMOTE_STORAGE_LINK "$RESOLVED_REMOTE_STORAGE_LINK"
fi

DOCKER_PLATFORM=$(docker_platform_for_arch "$REMOTE_ARCHITECTURE")
IMAGE_NAME=custom-jellyfin
IMAGE_TAG=10.11.8-custom
CUSTOM_IMAGE="$IMAGE_NAME:$IMAGE_TAG"

PLUGIN_ENABLED=0
PLUGIN_DIRECTORY=
PLUGIN_DLL_NAME=MyJellyfinPlugin.dll
PLUGIN_DLL_PATH=
if [ "$SKIP_PLUGIN" -eq 0 ]; then
    if [ ! -f "$PLUGIN_PROJECT_PATH" ]; then
        echo "Plugin project not found: $PLUGIN_PROJECT_PATH" >&2
        exit 1
    fi
    build_plugin_artifact "$PLUGIN_PROJECT_PATH"
    PLUGIN_ENABLED=1
fi

TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/jellyfin-deploy.XXXXXX")
trap 'rm -rf "$TEMP_ROOT"' EXIT
STAGING_ROOT="$TEMP_ROOT/stage"
ARTIFACT_ROOT="$STAGING_ROOT/artifacts"
NGINX_ROOT="$STAGING_ROOT/nginx"
SCRIPT_ROOT="$STAGING_ROOT/scripts"
ARCHIVE_PATH="$TEMP_ROOT/deployment.tar.gz"
IMAGE_ARCHIVE_PATH="$TEMP_ROOT/custom-jellyfin.tar"
REMOTE_ARCHIVE_PATH=/tmp/jellyfin-deployment.tar.gz
REMOTE_IMAGE_PATH=/tmp/custom-jellyfin.tar

mkdir -p "$ARTIFACT_ROOT" "$NGINX_ROOT" "$SCRIPT_ROOT" "$STAGING_ROOT/logs"

echo "Building the custom Jellyfin image archive for $DOCKER_PLATFORM"
pushd "$PROJECT_ROOT" >/dev/null
rm -f "$IMAGE_ARCHIVE_PATH"
run docker buildx build --platform "$DOCKER_PLATFORM" -t "$CUSTOM_IMAGE" --output "type=docker,dest=$IMAGE_ARCHIVE_PATH" .
popd >/dev/null

if [ ! -f "$IMAGE_ARCHIVE_PATH" ]; then
    echo "Archive not created: $IMAGE_ARCHIVE_PATH" >&2
    exit 1
fi

JELLYFIN_EXTRA_PORTS_BLOCK=
if [ "$ENABLE_DLNA" = true ]; then
    JELLYFIN_EXTRA_PORTS_BLOCK='    ports:
      - "7359:7359/udp"
      - "1900:1900/udp"'
fi

render_template "$TEMPLATE_ROOT/remote-docker-compose.yml.tpl" "$STAGING_ROOT/docker-compose.yml"
render_template "$TEMPLATE_ROOT/nginx-http.conf.tpl" "$NGINX_ROOT/http.conf"
render_template "$TEMPLATE_ROOT/nginx-https.conf.tpl" "$NGINX_ROOT/https.conf"
copy_text_lf "$TEMPLATE_ROOT/bootstrap.sh.tpl" "$SCRIPT_ROOT/bootstrap.sh"
copy_text_lf "$TEMPLATE_ROOT/finalize-tls.sh.tpl" "$SCRIPT_ROOT/finalize-tls.sh"
copy_text_lf "$TEMPLATE_ROOT/renew-certificates.sh.tpl" "$SCRIPT_ROOT/renew-certificates.sh"
chmod +x "$SCRIPT_ROOT"/*.sh

if [ "$PLUGIN_ENABLED" -eq 1 ]; then
    cp "$PLUGIN_DLL_PATH" "$ARTIFACT_ROOT/$PLUGIN_DLL_NAME"
    render_plugin_config "$TEMPLATE_ROOT/plugin-config.xml.tpl" "$ARTIFACT_ROOT/MyJellyfinPlugin.xml"
fi

cp -a "$TORRENT_SEARCH_SOURCE" "$STAGING_ROOT/Torrent-Search-API"

{
    printf 'DEPLOY_SSH_USER=%s\n' "$(shell_quote "$DEPLOY_SSH_USER")"
    printf 'JELLYFIN_DOMAIN=%s\n' "$(shell_quote "$JELLYFIN_DOMAIN")"
    printf 'LETSENCRYPT_EMAIL=%s\n' "$(shell_quote "$LETSENCRYPT_EMAIL")"
    printf 'REMOTE_APP_ROOT=%s\n' "$(shell_quote "$RESOLVED_REMOTE_APP_ROOT")"
    printf 'REMOTE_STORAGE_ROOT=%s\n' "$(shell_quote "$RESOLVED_REMOTE_STORAGE_ROOT")"
    printf 'REMOTE_STORAGE_LINK=%s\n' "$(shell_quote "$RESOLVED_REMOTE_STORAGE_LINK")"
    printf 'QBITTORRENT_USERNAME=%s\n' "$(shell_quote "$QBITTORRENT_USERNAME")"
    printf 'QBITTORRENT_PASSWORD=%s\n' "$(shell_quote "$QBITTORRENT_PASSWORD")"
    printf 'QBITTORRENT_WEBUI_PORT=%s\n' "$(shell_quote "$QBITTORRENT_WEBUI_PORT")"
    printf 'QBITTORRENT_TORRENT_PORT=%s\n' "$(shell_quote "$QBITTORRENT_TORRENT_PORT")"
    printf "QBITTORRENT_CATEGORY='jellyfin'\n"
    printf 'PLUGIN_ENABLED=%s\n' "$PLUGIN_ENABLED"
    printf 'PLUGIN_DIRECTORY=%s\n' "$(shell_quote "$PLUGIN_DIRECTORY")"
    printf 'PLUGIN_DLL_NAME=%s\n' "$(shell_quote "$PLUGIN_DLL_NAME")"
} > "$STAGING_ROOT/deploy.env"

run tar -czf "$ARCHIVE_PATH" -C "$STAGING_ROOT" .
run scp -P "$DEPLOY_SSH_PORT" "$ARCHIVE_PATH" "$DEPLOY_SSH_USER@$DEPLOY_SSH_HOST:$REMOTE_ARCHIVE_PATH"
run scp -P "$DEPLOY_SSH_PORT" "$IMAGE_ARCHIVE_PATH" "$DEPLOY_SSH_USER@$DEPLOY_SSH_HOST:$REMOTE_IMAGE_PATH"

q_app=$(shell_quote "$RESOLVED_REMOTE_APP_ROOT")
q_remote_archive=$(shell_quote "$REMOTE_ARCHIVE_PATH")
q_remote_image=$(shell_quote "$REMOTE_IMAGE_PATH")
remote_extract_command="mkdir -p $q_app && rm -rf $q_app/Torrent-Search-API $q_app/nginx $q_app/scripts $q_app/artifacts $q_app/logs $q_app/docker-compose.yml $q_app/deploy.env && tar -xzf $q_remote_archive -C $q_app && mv $q_remote_image $q_app/artifacts/custom-jellyfin.tar && rm -f $q_remote_archive"
run ssh -p "$DEPLOY_SSH_PORT" "$DEPLOY_SSH_USER@$DEPLOY_SSH_HOST" "$remote_extract_command"

bootstrap_command="bash $(shell_quote "$RESOLVED_REMOTE_APP_ROOT/scripts/bootstrap.sh")"
printf '>> ssh -p %q %q %q\n' "$DEPLOY_SSH_PORT" "$DEPLOY_SSH_USER@$DEPLOY_SSH_HOST" "$bootstrap_command"
printf '%s\n' "$DEPLOY_SUDO_PASSWORD" | ssh -p "$DEPLOY_SSH_PORT" "$DEPLOY_SSH_USER@$DEPLOY_SSH_HOST" "$bootstrap_command"

PROBE_URL="http://$JELLYFIN_DOMAIN/__jellyfin_deploy_probe"
echo "Waiting for the Cloudflare record to route $JELLYFIN_DOMAIN to this server"
echo "Probe URL: $PROBE_URL"
wait_for_probe "$PROBE_URL" "$PROBE_TIMEOUT_SECONDS"

finalize_command="bash $(shell_quote "$RESOLVED_REMOTE_APP_ROOT/scripts/finalize-tls.sh")"
printf '>> ssh -p %q %q %q\n' "$DEPLOY_SSH_PORT" "$DEPLOY_SSH_USER@$DEPLOY_SSH_HOST" "$finalize_command"
printf '%s\n' "$DEPLOY_SUDO_PASSWORD" | ssh -p "$DEPLOY_SSH_PORT" "$DEPLOY_SSH_USER@$DEPLOY_SSH_HOST" "$finalize_command"

echo
echo "Deployment complete."
echo "Jellyfin URL: https://$JELLYFIN_DOMAIN"
echo "Remote app root: $RESOLVED_REMOTE_APP_ROOT"
echo "Remote storage root: $RESOLVED_REMOTE_STORAGE_ROOT"
if [ -n "$RESOLVED_REMOTE_STORAGE_LINK" ]; then
    echo "Convenience symlink: $RESOLVED_REMOTE_STORAGE_LINK -> $RESOLVED_REMOTE_STORAGE_ROOT"
fi
echo "qBittorrent Web UI is bound to localhost:$QBITTORRENT_WEBUI_PORT on the target host."
echo "qBittorrent credentials: $QBITTORRENT_USERNAME / $QBITTORRENT_PASSWORD"
