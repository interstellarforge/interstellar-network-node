#!/usr/bin/env bash
set -Eeuo pipefail

REMOTE="${REMOTE:-origin}"
TOOLBOX="toolbox/interstellar-network-toolbox.sh"
ASSET="interstellar-network-toolbox.sh"

die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }

yes_no() {
  local answer
  read -r -p "$1 [Y/n] " answer
  answer="${answer:-y}"
  [[ "$answer" =~ ^[Yy]$ ]]
}

for cmd in git gh python3 sha256sum bash; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing command: $cmd"
done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Not a Git repository."
cd "$ROOT"
[[ -f "$TOOLBOX" ]] || die "Missing $TOOLBOX"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  read -r -p "Version to release (example: 4.3.1): " VERSION
fi
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] \
  || die "Invalid semantic version."

TAG="v${VERSION}"
BRANCH="$(git branch --show-current)"
[[ -n "$BRANCH" ]] || die "Detached HEAD is not supported."

gh auth status >/dev/null 2>&1 || die "Run: gh auth login"

info "Fetching remote state"
git fetch "$REMOTE" --tags --prune

# Recreate an accidentally-created release/tag if needed.
if gh release view "$TAG" >/dev/null 2>&1 || \
   git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1 || \
   git ls-remote --exit-code --tags "$REMOTE" "refs/tags/$TAG" >/dev/null 2>&1; then
  echo "Release/tag $TAG already exists."
  yes_no "Delete and recreate it?" || die "Cancelled."

  gh release delete "$TAG" --cleanup-tag --yes >/dev/null 2>&1 || true
  git push "$REMOTE" ":refs/tags/$TAG" >/dev/null 2>&1 || true
  git tag -d "$TAG" >/dev/null 2>&1 || true
fi

info "Updating toolbox version"
python3 - "$TOOLBOX" "$VERSION" <<'PY'
import re, sys
from pathlib import Path

path = Path(sys.argv[1])
version = sys.argv[2]
text = path.read_text()
new, count = re.subn(
    r'^VERSION="[^"]+"$',
    f'VERSION="{version}"',
    text,
    count=1,
    flags=re.M,
)
if count != 1:
    raise SystemExit("Could not find toolbox VERSION.")
path.write_text(new)
print(f"Toolbox VERSION -> {version}")
PY

info "Validating toolbox"
bash -n "$TOOLBOX"
git diff --check

if [[ -n "$(git status --porcelain)" ]]; then
  echo
  git status --short
  echo
  yes_no "Commit ALL changes shown above for $TAG?" || die "Cancelled."
  git add -A
  git commit -m "Release ${TAG}"
else
  info "Working tree is clean; release will use current HEAD."
fi

COMMITTED_VERSION="$(
  git show "HEAD:$TOOLBOX" |
    awk -F'"' '/^VERSION="/ {print $2; exit}'
)"
[[ "$COMMITTED_VERSION" == "$VERSION" ]] \
  || die "Committed toolbox VERSION is '$COMMITTED_VERSION', expected '$VERSION'."

info "Pushing ${BRANCH}"
git push "$REMOTE" "$BRANCH"

info "Creating and pushing ${TAG}"
git tag -a "$TAG" -m "Interstellar Network ${TAG}"
git push "$REMOTE" "$TAG"

DIST="$(mktemp -d)"
trap 'rm -rf "$DIST"' EXIT

cp "$TOOLBOX" "$DIST/$ASSET"
cp install.sh "$DIST/install.sh"

(
  cd "$DIST"
  sha256sum "$ASSET" install.sh > SHA256SUMS
)

info "Creating GitHub Release ${TAG}"
gh release create "$TAG" \
  --verify-tag \
  --title "Interstellar Network ${TAG}" \
  --generate-notes \
  "$DIST/$ASSET" \
  "$DIST/install.sh" \
  "$DIST/SHA256SUMS"

URL="$(gh release view "$TAG" --json url --jq '.url')"

echo
echo "============================================================"
echo " Interstellar Network ${TAG} released"
echo "============================================================"
echo "Release: $URL"
echo
echo "Nodes can now update from:"
echo "  interstellar → Toolbox & releases → Update to latest GitHub release"
