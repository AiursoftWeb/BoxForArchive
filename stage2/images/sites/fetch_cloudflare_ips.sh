#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ipv4_ranges=$(curl --fail --silent --show-error https://www.cloudflare.com/ips-v4 | tr '\n' ' ')
ipv6_ranges=$(curl --fail --silent --show-error https://www.cloudflare.com/ips-v6 | tr '\n' ' ')
all_ranges="$ipv4_ranges $ipv6_ranges"

[ -n "$ipv4_ranges" ] && [ -n "$ipv6_ranges" ] || {
    echo "Cloudflare returned an empty IP range list." >&2
    exit 1
}

cat > cloudflare_ips.conf <<EOF
(cloudflare_trust) {
    trusted_proxies static $all_ranges private_ranges
}

(limit_to_cloudflare) {
    @denied {
        not remote_ip $all_ranges
        not remote_ip {env.ALLOW_INCOMING_IPS}
        not remote_ip private_ranges
    }
    abort @denied
}
EOF
