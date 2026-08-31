#!/bin/bash
set -euo pipefail

if [ "${1:-}" != "--confirm" ]; then
    echo "Refusing to remove archive stacks without --confirm." >&2
    exit 1
fi

for stack in incoming download gitea peertube shepherd; do
    if sudo docker stack ls --format '{{.Name}}' | grep -Fxq "$stack"; then
        echo "Removing stack: $stack"
        sudo docker stack rm "$stack"
    fi
done

echo "Known BoxForArchive stacks were requested for removal. Data was not deleted."
