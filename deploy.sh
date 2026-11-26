#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

TARGET_STAGE=0
STACK_FILTER=
# Allow an early starting stage to run infrastructure with an intentionally unmatched filter.
ALLOW_INFRA_ONLY=0

print_info() { printf '\033[36m[ INFO ]\033[0m %s\n' "$*"; }
print_ok() { printf '\033[32m[  OK  ]\033[0m %s\n' "$*"; }
print_warn() { printf '\033[33m[ WARN ]\033[0m %s\n' "$*"; }
print_error() { printf '\033[31m[FAILED]\033[0m %s\n' "$*" >&2; }
fail() { print_error "$@"; exit 1; }

while (( $# )); do
    case "$1" in
        --stage)
            [[ "${2:-}" =~ ^[0-4]$ ]] || fail '--stage requires an integer from 0 to 4.'
            TARGET_STAGE=$2
            shift 2
            ;;
        --filter)
            [[ -n "${2:-}" && $2 != --* ]] || fail '--filter requires a stack-name substring.'
            STACK_FILTER=$2
            shift 2
            ;;
        -h|--help)
            printf '%s\n' 'Usage: deploy.sh [--stage 0..4] [--filter <stage-4 stack name substring>]'
            exit 0
            ;;
        *) fail "Unknown option: $1" ;;
    esac
done

STAGE4_STACKS=()
for compose_file in stage4/stacks/*/docker-compose.yml; do
    [[ -f "$compose_file" ]] || continue
    stack_dir=${compose_file%/*}
    stack_name=${stack_dir##*/}
    if [[ "$stack_name" == *"$STACK_FILTER"* ]]; then
        STAGE4_STACKS+=("$stack_name")
    fi
done
if (( ${#STAGE4_STACKS[@]} == 0 )); then
    if [[ -z "$STACK_FILTER" ]] || (( TARGET_STAGE == 4 || ! ALLOW_INFRA_ONLY )); then
        fail "No stage-4 stack matched the filter '$STACK_FILTER'."
    fi
    print_info "No stage-4 stack matched '$STACK_FILTER'; running infrastructure and shared preparation only."
fi

DOCKER=(sudo docker)
STACK_OPTIONS=(--prune --with-registry-auth)
REGISTRY_LOGGED_IN=0

ENV_FILE=
if [[ -f .env.prod ]]; then
    ENV_FILE=.env.prod
elif [[ -f .env ]]; then
    ENV_FILE=.env
fi
[[ -n "$ENV_FILE" ]] || fail "Missing .env.prod. Copy .env.example and fill in the required values."

get_env_value() {
    local key=$1 line
    [[ -n "$ENV_FILE" ]] || fail "No environment file found for $key."
    line=$(grep -m1 -E "^${key}=" "$ENV_FILE" || true)
    [[ -n "$line" && -n "${line#*=}" ]] || fail "'$key' is missing or empty in $ENV_FILE."
    printf '%s' "${line#*=}"
}

render_compose() {
    local template=$1 line key value
    if [[ -z "$ENV_FILE" ]]; then
        cat -- "$template"
        return
    fi
    # Feed sed the replacements on stdin so credentials stay out of process arguments.
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *=* && "$line" != \#* ]] || continue
        key=${line%%=*}
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        value=${line#*=}
        value=${value//\\/\\\\}
        value=${value//&/\\&}
        value=${value//\//\\/}
        printf 's/{{%s}}/%s/g\n' "$key" "$value"
    done < "$ENV_FILE" | sed -f - "$template" |
        sed '/{{[A-Z0-9_][A-Z0-9_]*}}/Q1' || {
            print_error "Could not render $template. Check for unresolved Compose variables."
            return 1
        }
}

deploy_stack() {
    local template=$1 stack_name=$2 resolve=$3 compose
    shift 3
    # Render completely before Docker sees the stack. The marker preserves trailing YAML newlines.
    compose=$(render_compose "$template" "$@" && printf '.') || return 1
    print_info "Deploying stack '$stack_name'."
    printf '%s' "${compose%.}" |
        "${DOCKER[@]}" stack deploy --compose-file - --detach "${STACK_OPTIONS[@]}" --resolve-image "$resolve" "$stack_name"
}

ensure_overlay_network() {
    local name=$1
    shift
    if ! "${DOCKER[@]}" network inspect "$name" >/dev/null 2>&1; then
        print_info "Creating overlay network '$name'."
        "${DOCKER[@]}" network create --driver overlay --attachable --scope swarm "$@" "$name" >/dev/null
    fi
}

verify_overlay_network() {
    local name=$1
    [[ $("${DOCKER[@]}" network inspect --format '{{.Driver}} {{.Scope}}' "$name") == 'overlay swarm' ]] ||
        fail "The $name network must be a Swarm overlay."
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
    print_info "Installing the minimal archive host dependencies..."
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        ca-certificates curl docker-buildx docker-compose-v2 docker.io jq
    sudo systemctl enable --now docker
    sudo usermod -aG docker "$USER"
    print_ok "Host dependencies are ready."
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

    local allowed='^(incoming|download|gitea|peertube|shepherd|offline-bundles)$'
    local unknown_stacks
    unknown_stacks=$(sudo docker stack ls --format '{{.Name}}' | grep -Ev "$allowed" || true)
    [ -z "$unknown_stacks" ] || fail "Unknown legacy stacks are still present: $(echo "$unknown_stacks" | tr '\n' ' ')"
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

    print_info "Logging in to $host..."
    printf '%s' "$password" | sudo docker login "$host" --username "$username" --password-stdin
    unset password
    sudo docker manifest inspect "$host/$verification_image" >/dev/null
    REGISTRY_LOGGED_IN=1
    print_ok "PubHub access verified with $verification_image."
}

validate_recovered_data() {
    local stack_name=$1
    case "$stack_name" in
        download)
            sudo test -d /swarm-vol/download-data || fail "Missing /swarm-vol/download-data; refusing to create an empty download service."
            sudo find /swarm-vol/download-data -type f -print -quit | grep . >/dev/null || fail "Download data contains no files."
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

stage0() {
    install_host_dependencies
    setup_docker_auto_clean
}

prepare_deployment() {
    ensure_commands
    ensure_independent_swarm
    ensure_overlay_network proxy_app --subnet 10.233.0.0/16 --opt com.docker.network.driver.mtu=1400
    verify_overlay_network proxy_app
    ensure_caddy_data_directory
}

stage2() {
    login_to_registry
    local image_dir=stage2/images/sites
    rm -rf "$image_dir/discovered" "$image_dir/Dist"
    mkdir -p "$image_dir/discovered"
    find stage4/stacks -name '*.conf' -type f -exec cp {} "$image_dir/discovered/" \;

    (
        cd "$image_dir"
        ./build_proxy.sh
    )

    print_info "Building the local archive Caddy image from PubHub base images..."
    sudo docker build --pull --tag boxforarchive/archive-caddy:latest "$image_dir"
    deploy_stack stage2/stacks/incoming/docker-compose.yml incoming never

    # Rebuilt local tags leave the Swarm spec unchanged; recreate Caddy from the local image.
    sudo docker service update --force --no-resolve-image incoming_sites
}

prepare_business_stacks() {
    local stack_name
    login_to_registry
    for stack_name in "${STAGE4_STACKS[@]}"; do
        validate_recovered_data "$stack_name"
    done
}

stage4() {
    local stack_name
    prepare_business_stacks
    for stack_name in "${STAGE4_STACKS[@]}"; do
        deploy_stack "stage4/stacks/$stack_name/docker-compose.yml" "$stack_name" always
    done
}

configure_docker_storage_dependency

if (( TARGET_STAGE <= 0 )); then
    print_info "Stage 0: prepare the host and Swarm."
    stage0
fi

prepare_deployment

if (( TARGET_STAGE <= 2 )); then
    print_info "Stage 2: deploy the incoming proxy."
    stage2
fi

print_info "Stage 4: deploy business stacks."
stage4
"${DOCKER[@]}" stack ls
