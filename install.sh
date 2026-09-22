#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${INTERSTELLAR_RELEASE_REPO:-interstellarforge/interstellar-network-node}"
TOOLBOX_ASSET="interstellar-network-toolbox.sh"
SUMS_ASSET="SHA256SUMS"
TARGET="/usr/local/sbin/interstellar-toolbox"

[[ "$EUID" -eq 0 ]] || {
  echo "Run this installer with sudo/root."
  exit 1
}

for cmd in curl sha256sum awk bash install; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Missing required command: $cmd"
    exit 1
  }
done

EFFECTIVE="$(
  curl -fsSIL -o /dev/null -w '%{url_effective}' \
    "https://github.com/${REPO}/releases/latest"
)"
VERSION="${EFFECTIVE##*/}"
VERSION="${VERSION#v}"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
  echo "Could not determine latest release."
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Installing Interstellar Network ${VERSION}..."

curl -fL --retry 3 \
  "https://github.com/${REPO}/releases/download/v${VERSION}/${TOOLBOX_ASSET}" \
  -o "$TMP/$TOOLBOX_ASSET"

curl -fL --retry 3 \
  "https://github.com/${REPO}/releases/download/v${VERSION}/${SUMS_ASSET}" \
  -o "$TMP/$SUMS_ASSET"

EXPECTED="$(
  awk -v file="$TOOLBOX_ASSET" '$2 == file || $2 == ("*" file) {print $1; exit}' \
    "$TMP/$SUMS_ASSET"
)"
ACTUAL="$(sha256sum "$TMP/$TOOLBOX_ASSET" | awk '{print $1}')"

[[ "$EXPECTED" =~ ^[0-9a-fA-F]{64}$ && "${EXPECTED,,}" == "${ACTUAL,,}" ]] || {
  echo "SHA-256 verification failed."
  exit 1
}

bash -n "$TMP/$TOOLBOX_ASSET"

install -o root -g root -m 0700 "$TMP/$TOOLBOX_ASSET" "$TARGET"

cat >/usr/local/bin/interstellar <<'EOF'
#!/bin/sh
if [ "$(id -u)" -eq 0 ]; then
  exec /usr/local/sbin/interstellar-toolbox "$@"
else
  exec sudo /usr/local/sbin/interstellar-toolbox "$@"
fi
EOF
chown root:root /usr/local/bin/interstellar
chmod 0755 /usr/local/bin/interstellar

echo
echo "Installed Interstellar Network ${VERSION}."
echo "Run:"
echo "  interstellar"
