# BoxForArchive

`BoxForArchive` is the storage-heavy, low-cost archive node for three global services:

- `download.anduinos.com`
- `git.aiursoft.com`
- `videos.aiursoft.com`

It is intentionally an independent, single-node Docker Swarm. It does not join the
Emergency Swarm and does not run a local registry, Puller, Zot, ClickHouse, Grafana,
Pysyncer, or HTTP access-log pipeline.

## Architecture

- Images are pulled directly from `pubhub.aiursoft.com`.
- Caddy is built locally from PubHub base images and runs only on this node.
- Business data remains in bind mounts under `/swarm-vol`.
- Docker's own runtime data remains on the system disk by default.
- The deployment never formats, mounts, deletes, or creates the recovered business
  data directories.
- HTTP access logging is deliberately disabled. Caddy and Docker may still emit
  operational error messages to container stdout.

Expected recovered data paths:

```text
/swarm-vol/download-data
/swarm-vol/gitea-data
/swarm-vol/peertube
```

The deployment refuses to start a selected business stack unless its recovery
markers are present. This prevents a missing mount from silently becoming a new,
empty production database.

## First deployment

```bash
cd /swarm-vol
git clone ssh://git@ssh.aiursoft.com:2202/aiursoft/boxforarchive.git boxforarchive
cd /swarm-vol/boxforarchive
cp .env.example .env.prod
$EDITOR .env.prod
./deploy.sh
```

`stage0` installs Docker and initializes an independent single-node Swarm.
`stage2` builds and deploys Caddy. `stage4` deploys the three archive services and
Shepherd. Stages 1 and 3 intentionally do not exist.

## Targeted deployment

```bash
# Rebuild Caddy, then continue into stage 4.
./deploy.sh --stage 2

# Deploy only one recovered business stack.
./deploy.sh --stage 4 --filter gitea
./deploy.sh --stage 4 --filter download
./deploy.sh --stage 4 --filter peertube

# Deploy only the image updater.
./deploy.sh --stage 4 --filter shepherd
```

The HTTPS hostnames should be moved to this node only after the corresponding
service reports healthy. Gitea's separate SSH endpoint is not handled by Caddy.

Required public DNS records for the archive node at `31.56.26.15`:

| Type | Hostname | Cloudflare proxy | Purpose |
| --- | --- | --- | --- |
| A | `download.anduinos.com` | Proxied | Download web service |
| A | `git.aiursoft.com` | Proxied | Gitea web and Smart HTTP |
| A | `videos.aiursoft.com` | Proxied | PeerTube web and media |
| A | `gitea-ssh.aiursoft.com` | DNS only | Gitea SSH on TCP port 2201 |

Cloudflare's ordinary HTTP proxy cannot carry Gitea's TCP/2201 SSH endpoint.
Keep `gitea-ssh.aiursoft.com` DNS-only; Gitea advertises clone URLs in the form
`ssh://git@gitea-ssh.aiursoft.com:2201/owner/repository.git`.

## Safety properties

- The script fails if the current Swarm contains another node.
- The script fails if unknown legacy stacks remain in the Swarm.
- No local registry or insecure registry is configured.
- No automatic Docker volume or system prune is installed.
- `alldrop.sh` removes only this Box's five known stacks and requires an explicit
  `--confirm` argument.
