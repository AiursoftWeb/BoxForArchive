#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

STACK_FILTER=""
TARGET_STAGE=0
REGISTRY_LOGGED_IN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --filter)
            [ -n "${2:-}" ] || { echo "--filter requires a value" >&2; exit 1; }
            STACK_FILTER="$2"
            shift 2
            ;;
        --stage)
            [[ "${2:-}" =~ ^[0-4]$ ]] || { echo "--stage requires an integer from 0 to 4" >&2; exit 1; }
            TARGET_STAGE="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [ -f .env.prod ]; then
    ENV_FILE=.env.prod
elif [ -f .env ]; then
    ENV_FILE=.env
else
    echo "Missing .env.prod. Copy .env.example and fill in the required values." >&2
    exit 1
fi

info() { printf '\033[36m[ INFO ]\033[0m %s\n' "$*"; }
ok() { printf '\033[32m[  OK  ]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[ WARN ]\033[0m %s\n' "$*"; }
fail() { printf '\033[31m[FAILED]\033[0m %s\n' "$*" >&2; exit 1; }

get_env_value() {
    local key=$1
    local line
    line=$(grep -m1 -E "^${key}=" "$ENV_FILE" || true)
    [ -n "$line" ] && [ -n "${line#*=}" ] || fail "'$key' is missing or empty in $ENV_FILE."
    printf '%s' "${line#*=}"
}

ensure_commands() {
    local missing=()
    local command_name
    for command_name in docker curl jq; do
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
    done
    [ "${#missing[@]}" -eq 0 ] || fail "Missing commands: ${missing[*]}. Run ./deploy.sh --stage 0 first."
}

configure_docker_storage_dependency() {
    local temp_file
    local drop_in=/etc/systemd/system/docker.service.d/storage-mounts.conf
    temp_file=$(mktemp)
    cat > "$temp_file" <<'EOF'
[Unit]
RequiresMountsFor=/swarm-vol
ConditionPathIsMountPoint=/swarm-vol
EOF

    sudo mkdir -p "$(dirname "$drop_in")"
    if ! sudo cmp -s "$temp_file" "$drop_in"; then
        sudo install -m 0644 "$temp_file" "$drop_in"
        sudo systemctl daemon-reload
    fi
    rm -f "$temp_file"
}

install_host_dependencies() {
    info "Installing the minimal archive host dependencies..."
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        ca-certificates curl docker-buildx docker-compose-v2 docker.io jq
    sudo systemctl enable --now docker
    sudo usermod -aG docker "$USER"
    ok "Host dependencies are ready."
}

function setup_docker_auto_clean() {
    echo "Configuring Docker cleanup every 23 hours..."
    local temp_dir
    local unit
    local changed=0
    temp_dir=$(mktemp -d)

    # Keep the existing unit names so upgrades replace the old disk monitor.
    cat > "$temp_dir/docker-disk-monitor.service" <<'EOF'
[Unit]
Description=Prune unused Docker data
After=docker.service

[Service]
Type=oneshot
ExecCondition=/usr/bin/systemctl is-active --quiet docker.service
ExecStart=/usr/bin/docker system prune -a -f
User=root
EOF

    cat > "$temp_dir/docker-disk-monitor.timer" <<'EOF'
[Unit]
Description=Prune unused Docker data every 23 hours

[Timer]
OnActiveSec=23h
OnUnitActiveSec=23h
Unit=docker-disk-monitor.service

[Install]
WantedBy=timers.target
EOF

    for unit in docker-disk-monitor.service docker-disk-monitor.timer; do
        if ! sudo cmp -s "$temp_dir/$unit" "/etc/systemd/system/$unit"; then
            sudo install -m 0644 "$temp_dir/$unit" "/etc/systemd/system/$unit"
            changed=1
        fi
    done
    rm -rf "$temp_dir"
    sudo rm -f /usr/local/bin/docker-disk-monitor.sh

    if [ "$changed" -eq 1 ]; then
        sudo systemctl daemon-reload
        sudo systemctl enable docker-disk-monitor.timer
        sudo systemctl restart docker-disk-monitor.timer
    else
        # Starting an already active timer leaves its schedule unchanged.
        sudo systemctl enable --now docker-disk-monitor.timer
    fi
}

configure_docker_daemon() {
    if sudo test -f /etc/docker/daemon.json && sudo jq -e '."userland-proxy" == false' /etc/docker/daemon.json >/dev/null; then
        return
    fi
    [ "$(sudo docker info --format '{{.Swarm.LocalNodeState}}')" = "inactive" ] || fail "Configure userland-proxy=false during maintenance before deploying."
    local config
    config=$(mktemp)
    if sudo test -f /etc/docker/daemon.json; then sudo cat /etc/docker/daemon.json; else echo '{}'; fi | jq '. + {"userland-proxy": false}' > "$config"
    sudo dockerd --validate --config-file="$config"
    sudo install -D -m 0644 "$config" /etc/docker/daemon.json
    rm -f "$config"
    sudo systemctl restart docker.service
}

function ensure_docker_network() {
    local swarm
    swarm=$(sudo docker info --format '{{.Swarm.LocalNodeState}} {{.Swarm.ControlAvailable}} {{.Swarm.Nodes}}')
    [[ "$swarm" = "inactive false 0" || "$swarm" = "active true 1" ]] || { echo "Expected a new host or an independent Swarm manager." >&2; return 1; }
    sudo test ! -f /var/lib/box-docker-network/pending.json || { echo "Finish the pending network migration before deploying." >&2; return 1; }
    sudo jq -e '."userland-proxy" == false' /etc/docker/daemon.json >/dev/null || { echo "Configure userland-proxy=false before initializing the gateway." >&2; return 1; }
    if sudo docker network inspect docker_gwbridge >/dev/null 2>&1; then
        [ "$(sudo docker network inspect --format '{{.Driver}} {{.EnableIPv6}} {{index .Options "com.docker.network.bridge.name"}}' docker_gwbridge)" = "bridge true docker_gwbridge" ] || { echo "Existing Docker gateway is not dual-stack; migrate it before deploying." >&2; return 1; }
    else
        [ "$swarm" = "inactive false 0" ] || { echo "Active Swarm has no gateway; repair it before deploying." >&2; return 1; }
        sudo docker network create --driver bridge --ipv6 --opt com.docker.network.bridge.name=docker_gwbridge --opt com.docker.network.bridge.enable_icc=false --opt com.docker.network.bridge.enable_ip_masquerade=true docker_gwbridge
    fi
    if [ "$swarm" = "inactive false 0" ]; then
        sudo docker swarm init --advertise-addr "$(hostname -I | awk '{print $1}')"
    fi
}

ensure_independent_swarm() {
    configure_docker_daemon
    ensure_docker_network
    sudo docker node ls >/dev/null 2>&1 || fail "This node is not a Swarm manager. BoxForArchive must remain independent."
    local node_count
    node_count=$(sudo docker node ls -q | wc -l | tr -d ' ')
    [ "$node_count" = "1" ] || fail "This Swarm contains $node_count nodes. BoxForArchive requires exactly one node."

    local allowed='^(incoming|download|gitea|peertube|shepherd)$'
    local unknown_stacks
    unknown_stacks=$(sudo docker stack ls --format '{{.Name}}' | grep -Ev "$allowed" || true)
    [ -z "$unknown_stacks" ] || fail "Unknown legacy stacks are still present: $(echo "$unknown_stacks" | tr '\n' ' ')"
}

ensure_proxy_network() {
    if ! sudo docker network inspect proxy_app >/dev/null 2>&1; then
        info "Creating the archive proxy overlay network..."
        sudo docker network create \
            --driver overlay \
            --attachable \
            --subnet 10.233.0.0/16 \
            --opt com.docker.network.driver.mtu=1400 \
            --scope swarm \
            proxy_app >/dev/null
    else
        local network_type
        network_type=$(sudo docker network inspect --format '{{.Driver}} {{.Scope}}' proxy_app)
        [ "$network_type" = "overlay swarm" ] || fail "Existing proxy_app network is '$network_type', expected 'overlay swarm'."
    fi
}

ensure_caddy_data_directory() {
    sudo mkdir -p /swarm-vol/sites-data
}

login_to_registry() {
    [ "$REGISTRY_LOGGED_IN" = "1" ] && return
    local host username password verification_image
    host=$(get_env_value REGISTRY_HOST)
    username=$(get_env_value REGISTRY_USERNAME)
    password=$(get_env_value REGISTRY_PASSWORD)
    verification_image=$(get_env_value REGISTRY_VERIFICATION_IMAGE)

    info "Logging in to $host..."
    printf '%s' "$password" | sudo docker login "$host" --username "$username" --password-stdin
    unset password
    sudo docker manifest inspect "$host/$verification_image" >/dev/null
    REGISTRY_LOGGED_IN=1
    ok "PubHub access verified with $verification_image."
}

render_compose() {
    local source_file=$1
    local output_file=$2
    cp "$source_file" "$output_file"
    chmod 600 "$output_file"

    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        local escaped_value
        escaped_value=$(printf '%s' "$value" | sed -e 's/[\/&]/\\&/g')
        sed -i "s/{{$key}}/$escaped_value/g" "$output_file"
    done < "$ENV_FILE"

    if grep -Eq '{{[A-Z0-9_]+}}' "$output_file"; then
        local unresolved
        unresolved=$(grep -Eo '{{[A-Z0-9_]+}}' "$output_file" | sort -u | tr '\n' ' ')
        rm -f "$output_file"
        fail "Unresolved compose variables: $unresolved"
    fi
}

deploy_stack() {
    local compose_file=$1
    local stack_name=$2
    local resolve_mode=${3:-always}
    local rendered
    rendered=$(mktemp)
    render_compose "$compose_file" "$rendered"

    info "Deploying stack '$stack_name'..."
    if ! sudo docker stack deploy \
        --compose-file "$rendered" \
        --detach \
        --prune \
        --with-registry-auth \
        --resolve-image "$resolve_mode" \
        "$stack_name"; then
        rm -f "$rendered"
        fail "Failed to deploy stack '$stack_name'."
    fi
    rm -f "$rendered"
}

validate_recovered_data() {
    local stack_name=$1
    case "$stack_name" in
        download)
            sudo test -d /swarm-vol/download-data || fail "Missing /swarm-vol/download-data; refusing to create an empty download service."
            sudo find /swarm-vol/download-data -type f -print -quit | grep -q . || fail "Download data contains no files."
            ;;
        gitea)
            sudo test -s /swarm-vol/gitea-data/gitea/gitea.db || fail "Missing recovered Gitea database."
            ;;
        peertube)
            sudo test -s /swarm-vol/peertube/config/local-production.json || fail "Missing recovered PeerTube configuration."
            sudo test -s /swarm-vol/peertube/db17/PG_VERSION || fail "Missing restored PeerTube PostgreSQL 17 cluster."
            local postgres_version
            postgres_version=$(sudo cat /swarm-vol/peertube/db17/PG_VERSION)
            [ "$postgres_version" = "17" ] || fail "PeerTube requires the restored PostgreSQL 17 cluster; found '$postgres_version'."
            sudo test -d /swarm-vol/peertube/data || fail "Missing recovered PeerTube data directory."
            ;;
    esac
}

build_and_deploy_caddy() {
    local image_dir=stage2/images/sites
    rm -rf "$image_dir/discovered" "$image_dir/Dist"
    mkdir -p "$image_dir/discovered"
    find stage4/stacks -name '*.conf' -type f -exec cp {} "$image_dir/discovered/" \;

    (
        cd "$image_dir"
        ./build_proxy.sh
    )

    info "Building the local archive Caddy image from PubHub base images..."
    sudo docker build --pull --tag boxforarchive/archive-caddy:latest "$image_dir"
    deploy_stack stage2/stacks/incoming/docker-compose.yml incoming never

    # Rebuilt local tags leave the Swarm spec unchanged; recreate Caddy from the local image.
    sudo docker service update --force --no-resolve-image incoming_sites
}

deploy_business_stacks() {
    local selected=()
    local compose_file stack_name
    while IFS= read -r -d '' compose_file; do
        stack_name=$(basename "$(dirname "$compose_file")")
        if [ -z "$STACK_FILTER" ] || [[ "$stack_name" == *"$STACK_FILTER"* ]]; then
            selected+=("$stack_name:$compose_file")
        else
            info "Skipping stack '$stack_name' due to filter."
        fi
    done < <(find stage4/stacks -name docker-compose.yml -type f -print0 | sort -z)

    [ "${#selected[@]}" -gt 0 ] || fail "No stage4 stack matched filter '$STACK_FILTER'."

    local item
    for item in "${selected[@]}"; do
        stack_name=${item%%:*}
        validate_recovered_data "$stack_name"
    done
    for item in "${selected[@]}"; do
        stack_name=${item%%:*}
        compose_file=${item#*:}
        deploy_stack "$compose_file" "$stack_name" always
    done
}

configure_docker_storage_dependency

if [ "$TARGET_STAGE" -le 0 ]; then
    install_host_dependencies
    setup_docker_auto_clean
fi

ensure_commands
ensure_independent_swarm
ensure_proxy_network
ensure_caddy_data_directory

if [ "$TARGET_STAGE" -le 1 ]; then
    info "Stage 1 intentionally has no local image mirror. PubHub is used directly."
fi

if [ "$TARGET_STAGE" -le 2 ]; then
    login_to_registry
    build_and_deploy_caddy
    ok "Stage 2 complete: archive Caddy is deployed without HTTP access logging."
fi

if [ "$TARGET_STAGE" -le 3 ]; then
    info "Stage 3 intentionally has no Registry, Puller, ClickHouse, or authentication stack."
fi

if [ "$TARGET_STAGE" -le 4 ]; then
    login_to_registry
    deploy_business_stacks
    ok "Stage 4 complete: selected archive stacks were deployed."
fi

sudo docker stack ls
