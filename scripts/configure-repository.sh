#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${1:-}"
[[ "$REPO" =~ ^[^/]+/[^/]+$ ]] || {
  echo "Usage: $0 owner/repository"
  exit 1
}

python3 - "$REPO" <<'PY'
import sys
from pathlib import Path

repo = sys.argv[1]
path = Path("toolbox/interstellar-network-toolbox.sh")
text = path.read_text()
import re
text, n = re.subn(
    r'^RELEASE_REPO="\$\{INTERSTELLAR_RELEASE_REPO:-[^}]+\}"$',
    f'RELEASE_REPO="${{INTERSTELLAR_RELEASE_REPO:-{repo}}}"',
    text,
    count=1,
    flags=re.M,
)
if n != 1:
    raise SystemExit("Could not update RELEASE_REPO.")
path.write_text(text)

for p in [Path("README.md"), Path("install.sh")]:
    t = p.read_text()
    t = t.replace("interstellarforge/interstellar-network-node", repo)
    p.write_text(t)

print(f"Release repository configured as {repo}")
PY
