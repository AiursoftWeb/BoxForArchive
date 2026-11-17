<a name="boxforarchive"></a>

# Aiursoft BoxForArchive

## Overview

### What is BoxForArchive?

`BoxForArchive` is the storage-heavy, low-cost archive node for three global services:

- `download.anduinos.com`
- `git.aiursoft.com`
- `videos.aiursoft.com`

It is intentionally an independent, single-node Docker Swarm. It does not join the
Emergency Swarm and does not run a local registry, Puller, Zot, ClickHouse, Grafana,
Pysyncer, or HTTP access-log pipeline.

## Installation

Use a dedicated Linux host with systemd, Git, Bash and sudo access for this Box. The deployment entry point changes host configuration, installs or configures Docker, and deploys Docker Swarm services. Prepare the intended host, its storage and network access before running it.

Fetch the configuration repository:

```bash
git clone https://gitlab.aiursoft.com/aiursoft/boxforarchive.git
cd boxforarchive
```

Configure the private environment described in Configuration before deployment. This repository configures its named target; it is not a general-purpose installer for an unrelated workstation.

Recover and mount the existing business data under `/swarm-vol` first. The recovery markers described in Usage are required; cloning this repository does not restore that data.

## Usage

### Architecture

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

### Stacks included

Stage 2 contains `incoming` (Caddy). Stage 4 contains `download`, `gitea`, `peertube` and `shepherd`. Stages 1 and 3 are intentionally absent.

<a name="targeted-deployment"></a>

### Deployment operations

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

### Safety properties

- The script fails if the current Swarm contains another node.
- The script fails if unknown legacy stacks remain in the Swarm.
- No local registry or insecure registry is configured.
- No automatic Docker volume or system prune is installed.
- `alldrop.sh` removes only this Box's five known stacks and requires an explicit
  `--confirm` argument.

**Check the result.** On the target Swarm manager, inspect the selected stack and its tasks:

```bash
sudo docker stack ls
sudo docker stack services shepherd
sudo docker stack ps shepherd --no-trunc
```

Replace `shepherd` with the stack being inspected. Confirm the desired replicas, task errors and the service's own health endpoint or application behavior. A successful `docker stack deploy` submission does not prove every service is healthy. For a failed change, inspect task errors and restore a reviewed configuration through the same deployment entry point; preserve existing bind-mounted data.

## Configuration

`deploy.sh` reads `.env.prod` first and falls back to `.env`; it does not merge the two files. Keep real credentials in the private deployment environment. Values replace matching `{{VARIABLE_NAME}}` placeholders in temporary Compose copies; tracked Compose sources remain unchanged.

Prepare the private file from the tracked [.env.example](.env.example) reference and fill in the values required by the selected services:

```bash
cp .env.example .env.prod
$EDITOR .env.prod
```

`REGISTRY_HOST` and `REGISTRY_VERIFICATION_IMAGE` select the registry and the image used to verify access. `REGISTRY_USERNAME` and `REGISTRY_PASSWORD` provide PubHub credentials. `CLOUDFLARE_API_TOKEN` is used by Caddy; `PEERTUBE_POSTGRES_PASSWORD` and `PEERTUBE_SECRET` must match the recovered PeerTube installation. Missing or empty required values and unresolved Compose placeholders cause deployment to fail.

Service definitions and bind mounts live in `stage<N>/stacks/<stack-name>/docker-compose.yml`; custom image sources live in `stage<N>/images`. Review these files, the Caddy routes and any FRP configuration together before changing a service's exposure or storage. Keep existing database credentials and persistent data consistent during updates.

## Development

Validate the configuration using the repository's existing lint entry point:

```bash
bash -n deploy.sh
python3 ./lint.py
```

The linter requires Python 3 and PyYAML. The existing GitLab merge-request pipeline runs the repository's configured lint checks. Syntax and configuration checks do not deploy services or verify a live host.

<a name="first-deployment"></a>

Use the supported deployment entry point for the intended target:

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

## How to contribute

There are many ways to contribute to the project: logging bugs, submitting pull requests, reporting issues, and creating suggestions.

Even if you have push rights on the repository, you should create a personal fork and create feature branches there when you need them. This keeps the main repository clean and your workflow cruft out of sight.

We're also interested in your feedback on the future of this project. You can submit a suggestion or feature request through the issue tracker. To make this process more effective, we're asking that these include more information to help define them more clearly.

## License

This repository does not currently declare a license in a LICENSE file. Contact the maintainers before redistributing its contents.
