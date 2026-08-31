#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

mkdir -p Dist discovered
./fetch_cloudflare_ips.sh

find discovered -type f -name '*.conf' -print0 | sort -z | xargs -0 -r cat > Dist/Sites.temp
{
    cat cloudflare_ips.conf
    printf '\n\n'
    cat baseline
    printf '\n\n'
    cat Dist/Sites.temp
} > Dist/Caddyfile

echo "Built Caddyfile with HTTP access logging disabled."
