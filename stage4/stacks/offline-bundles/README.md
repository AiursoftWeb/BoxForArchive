# AnduinOS offline update publisher

One worker builds cumulative Resolute and Stonking bundles for AMD64 and ARM64
every 48 hours and publishes them to the dedicated R2 bucket. It has no HTTP endpoint or website dependency.
Each release group keeps three published batches; retired objects have a 24-hour
deletion grace. See the [publisher documentation](https://github.com/AiursoftWeb/anduinosofflinebundles/blob/master/docs/automation.md).

## First deployment

Prepare these directories under `/swarm-vol/anduinos-offline-bundles`:

- `data`: writable by UID/GID 10001, for schedules, archives and build evidence.
- `signing`: mode 0700, owned by 10001, containing the existing production GnuPG
  private key. Restore it from the controlled MS backup when moving hosts.
- `inputs`: read-only to the worker, containing the authenticated Ubuntu and
  AnduinOS public archive keyrings, original baseline metadata for each enabled group, and
  `keys/bundle-signing.gpg`.

The baseline paths relative to `inputs` are `baselines/2.0.0.status` and
`baselines/2.0.0.os-release` for AMD64, and
`baselines/resolute-arm64/2.0.1.status` and
`baselines/resolute-arm64/2.0.1.os-release` for ARM64. ARM64 first shipped in
2.0.1; do not substitute AMD64 metadata or a newer installation.

Stonking requires the original 2.1.0 installation metadata for each architecture:
`baselines/stonking-amd64/2.1.0.status` and `2.1.0.os-release` in that directory,
and the matching files under `baselines/stonking-arm64/`. Prepare these inputs
and qualify installation and reboot before applying the four-job configuration.
All four groups retain up to twelve visible archives. Adding a job makes its
first run due immediately without resetting another group's persisted schedule.

The public signing key is available at
<https://offline-update-packages.anduinos.com/sign-cert.gpg>. Its SHA-256 is
`4aee607db52c652290045b0b77c30d62adecff7bf3f6d801a66d38f9db5693df`, and its
OpenPGP fingerprint is `8F083DFE22EEC13D5FCB525E1EBE8FD7C3DA8DF4`.
The updater package checks the same SHA-256 when building. The worker
checks the public key and requires the existing private key; it never generates
or replaces a signing identity. Do not regenerate it on an empty mount.

Set only `OFFLINE_BUNDLES_R2_ACCESS_KEY` and `OFFLINE_BUNDLES_R2_SECRET_KEY` in
private `.env.prod`. The token is restricted to `anduinos-offline-updates`.
The endpoint, bucket, schedule and public key identity are reviewed in
[automation.json](automation.json). From the Box checkout, create the runtime
directory and copy the configuration before the first deployment:

```bash
sudo mkdir -p /swarm-vol/anduinos-offline-bundles/config
sudo cp stage4/stacks/offline-bundles/automation.json /swarm-vol/anduinos-offline-bundles/config/automation.json
```

Only this runtime directory is mounted read-only at `/config`; the container
never mounts the Box checkout. `deploy.sh` does not copy or manage this file.
When changing the configuration, repeat the copy and restart the worker to load it.

The image starts its default CLI command directly. The Stonking jobs require
OfflineBundles 10.0.16 or later to verify the SHA-512 package hashes in the
signed Ubuntu indexes. Synchronize the published image and prepare the baseline
inputs before enabling the jobs. Keep credentials out of this file.

Before enabling the stack, use the published image to run `automate --once`
with the same settings, mounts and resource limits. Verify the uploaded bundle
and catalog, and measure disk, memory and build duration. `--once` respects the
persisted schedule: the long-running worker then waits until the next due run.
Do not publish test-signed archives or enable other release groups without their
real baselines and installation/reboot acceptance.

The image is pulled directly from PubHub, so no Puller synchronization is
needed. Deploy through the normal Box stage 4 flow with filter `offline-bundles`.
The stage 4 preamble also checks registry login; the filter only selects
business stacks. Shepherd updates the image normally.
A single replica, local state lock, stop-first updates and a 120-second stop grace
preserve pending work during restarts. The worker uses up to 1 CPU and 2 GiB RAM.

## Signing key lifecycle

The production key was initialized once using GnuPG inside the published image,
on an empty private signing volume, with networking disabled. Its private bytes
stay on the publisher host and in the MS backup; only the exported binary public key is in R2.
The key has no automatic expiry and is not rotated by routine builds. A deliberate
rotation requires coordinated source review, new updater trust and old-client
compatibility planning. Never silently replace `sign-cert.gpg`.

Stop only this stack when pausing publication. Preserve the signing and data
volumes; a later restart resumes the same schedule and unfinished archive.
