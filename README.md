# Interstellar Network

Server/node tooling for **Interstellar Network**.

This repository publishes versioned GitHub releases of the Interstellar Network Toolbox.
The toolbox includes the read-only health agent used by the Home Assistant
**Interstellar Network** integration.

## Install

On a Debian/Ubuntu node:

```bash
curl -fL \
  https://github.com/interstellarforge/interstellar-network-node/releases/latest/download/install.sh \
  -o /tmp/interstellar-install.sh

sudo bash /tmp/interstellar-install.sh
```

Then run:

```bash
interstellar
```

## Updates

Inside the toolbox:

```text
Toolbox & releases
→ Check for updates
→ Update to latest GitHub release
```

Updates are downloaded from GitHub Releases and verified using SHA-256.

When the toolbox is updated, an already-installed health agent is refreshed from the
new toolbox release as well.

## Release model

A release contains:

- `interstellar-network-toolbox.sh`
- `install.sh`
- `SHA256SUMS`

Toolbox and embedded health-agent versions are independent. For example, a release may be:

```text
Interstellar Network Toolbox 4.3.1
Embedded health agent 3.0.0
```

Use semantic versioning for the toolbox.

## Releasing

From the repository root:

```bash
./scripts/release.sh 4.3.1
```

That one command:

1. validates repository state;
2. updates the toolbox `VERSION`;
3. commits pending changes;
4. pushes the branch;
5. creates and pushes `v4.3.1`;
6. packages and checksums release assets;
7. creates the GitHub Release;
8. uploads the assets.

## Security

The toolbox itself is installed root-only as:

```text
/usr/local/sbin/interstellar-toolbox
```

with mode `0700`.

The convenience command:

```text
/usr/local/bin/interstellar
```

uses `sudo`.

The health API remains read-only and localhost-only, with Tailscale Serve recommended
for remote access.
