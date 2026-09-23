#!/usr/bin/env python3
"""Add the Interstellar control grant to a tailnet policy file.

The tailnet policy file is HuJSON: JSON with comments and trailing commas.
Parsing it and writing JSON back would silently delete every comment the
operator wrote, so the grant is inserted textually and the rest of the file is
left byte for byte identical.

Nothing here writes without an explicit confirmation from the caller, the API's
own validation passing first, and an If-Match precondition so a concurrent edit
in the admin console aborts the write instead of being overwritten.

Standard library only; this runs on the node with no extra packages.
"""
from __future__ import annotations

import argparse
import difflib
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

API = os.environ.get("TS_GRANT_API") or "https://api.tailscale.com"
# Passed by environment, never argv: /proc/<pid>/cmdline is world readable while
# /proc/<pid>/environ is not.
CREDENTIAL_ENV = "TS_GRANT_CREDENTIAL"
CODE, STRING, COMMENT = "code", "string", "comment"


# --------------------------------------------------------------------------
# HuJSON handling
# --------------------------------------------------------------------------

def scan(text: str):
    """Classify every character as code, string or comment.

    Needed because a `//` inside a string is not a comment and a `{` inside a
    comment is not structure. Everything else here depends on getting that right.
    """
    kinds = [CODE] * len(text)
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch == '"':
            kinds[i] = STRING
            i += 1
            while i < n:
                kinds[i] = STRING
                if text[i] == "\\":
                    if i + 1 < n:
                        kinds[i + 1] = STRING
                    i += 2
                    continue
                if text[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                kinds[i] = COMMENT
                i += 1
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "*":
            kinds[i] = kinds[i + 1] = COMMENT
            i += 2
            while i < n:
                kinds[i] = COMMENT
                if text[i] == "*" and i + 1 < n and text[i + 1] == "/":
                    kinds[i + 1] = COMMENT
                    i += 2
                    break
                i += 1
            continue
        i += 1
    return kinds


def to_json(text: str) -> str:
    """Strip HuJSON comments and trailing commas so json.loads can read it."""
    kinds = scan(text)
    kept = []
    for i, ch in enumerate(text):
        if kinds[i] == COMMENT:
            # Keep newlines so error line numbers stay meaningful.
            kept.append("\n" if ch == "\n" else " ")
        else:
            kept.append(ch)
    stripped = "".join(kept)
    kinds = scan(stripped)
    out = list(stripped)
    for i, ch in enumerate(stripped):
        if ch != "," or kinds[i] != CODE:
            continue
        j = i + 1
        while j < len(stripped) and (stripped[j].isspace() or kinds[j] == COMMENT):
            j += 1
        if j < len(stripped) and stripped[j] in "]}" and kinds[j] == CODE:
            out[i] = " "
    return "".join(out)


def parse(text: str) -> dict:
    return json.loads(to_json(text))


def find_top_level_array(text: str, key: str) -> int | None:
    """Return the index just after the `[` of a top-level array, or None.

    Only depth-1 keys count, so a nested "grants" inside another object or
    inside "tests" is never mistaken for the real one.
    """
    kinds = scan(text)
    depth = 0
    i, n = 0, len(text)
    target = f'"{key}"'
    while i < n:
        if kinds[i] == COMMENT:
            i += 1
            continue
        ch = text[i]
        if kinds[i] == CODE and ch in "{[":
            depth += 1
            i += 1
            continue
        if kinds[i] == CODE and ch in "}]":
            depth -= 1
            i += 1
            continue
        if depth == 1 and kinds[i] == STRING and text.startswith(target, i):
            j = i + len(target)
            while j < n and (text[j].isspace() or kinds[j] == COMMENT):
                j += 1
            if j < n and text[j] == ":":
                j += 1
                while j < n and (text[j].isspace() or kinds[j] == COMMENT):
                    j += 1
                if j < n and text[j] == "[":
                    return j + 1
                return None
            i = j
            continue
        i += 1
    return None


def find_object_start(text: str) -> int | None:
    """Index just after the opening `{` of the top-level object."""
    kinds = scan(text)
    for i, ch in enumerate(text):
        if kinds[i] == CODE and ch == "{":
            return i + 1
        if kinds[i] == CODE and not ch.isspace():
            return None
    return None


def line_indent(text: str, index: int) -> str:
    start = text.rfind("\n", 0, index) + 1
    line = text[start:index]
    return line[:len(line) - len(line.lstrip())]


# --------------------------------------------------------------------------
# Grant construction and detection
# --------------------------------------------------------------------------

def build_grant(src: list[str], dst: list[str], port: int, capability: str) -> dict:
    return {"src": src, "dst": dst, "ip": [f"tcp:{port}"], "app": {capability: [{}]}}


def grant_matches(grant: dict, src: list[str], dst: list[str], port: int, capability: str) -> bool:
    """True when this grant already gives src->dst the capability on the port."""
    if not isinstance(grant, dict):
        return False
    app = grant.get("app")
    if not isinstance(app, dict) or capability not in app:
        return False
    have_src = {str(x) for x in grant.get("src", []) if isinstance(x, (str, int))}
    have_dst = {str(x) for x in grant.get("dst", []) if isinstance(x, (str, int))}
    if not set(src) <= have_src or not set(dst) <= have_dst:
        return False
    ports = grant.get("ip")
    if ports is None:
        return True  # no ip restriction means all ports
    allowed = {str(x) for x in ports if isinstance(x, (str, int))}
    return f"tcp:{port}" in allowed or "*" in allowed or f"tcp:*" in allowed


def has_grant(policy: dict, src, dst, port, capability) -> bool:
    grants = policy.get("grants")
    if not isinstance(grants, list):
        return False
    return any(grant_matches(g, src, dst, port, capability) for g in grants)


def render_grant(grant: dict, indent: str) -> str:
    """Render compactly, the way policy files are normally written by hand.

    json.dumps(indent=2) puts every array element on its own line, which looks
    nothing like the surrounding file. No trailing commas inside the object, so
    the result is also valid strict JSON.
    """
    def array(values):
        return "[" + ", ".join(json.dumps(v) for v in values) + "]"

    capability = next(iter(grant["app"]))
    lines = [
        "{",
        f'  "src": {array(grant["src"])},',
        f'  "dst": {array(grant["dst"])},',
        f'  "ip":  {array(grant["ip"])},',
        f'  "app": {{{json.dumps(capability)}: [{{}}]}}',
        "}",
    ]
    return "\n".join(indent + line for line in lines)


def insert_grant(text: str, grant: dict) -> str:
    """Insert the grant into the policy text, preserving everything else.

    Raises ValueError when the insertion point cannot be located confidently,
    so the caller can fall back to printing the snippet instead of guessing.
    """
    note = "// Interstellar Network: Home Assistant control plane."
    position = find_top_level_array(text, "grants")
    if position is not None:
        indent = line_indent(text, position) + "  "
        block = render_grant(grant, indent)
        return f"{text[:position]}\n{indent}{note}\n{block},\n{text[position:].lstrip(chr(10))}"

    if "grants" in parse(text):
        raise ValueError('"grants" exists but is not a plain array literal; edit the policy by hand')

    start = find_object_start(text)
    if start is None:
        raise ValueError("policy file does not start with a JSON object")
    indent = line_indent(text, start) + "  "
    block = render_grant(grant, indent + "  ")
    return (f"{text[:start]}\n{indent}\"grants\": [\n{indent}  {note}\n{block},\n{indent}],"
            f"\n{text[start:].lstrip(chr(10))}")


def diff(before: str, after: str) -> str:
    return "".join(difflib.unified_diff(
        before.splitlines(keepends=True), after.splitlines(keepends=True),
        fromfile="current policy", tofile="proposed policy", n=3))


# --------------------------------------------------------------------------
# Tailscale API
# --------------------------------------------------------------------------

class ApiError(Exception):
    pass


def request(method, url, token=None, body=None, content_type=None, etag=None, form=None):
    data = None
    headers = {}
    if form is not None:
        data = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif body is not None:
        data = body.encode()
        headers["Content-Type"] = content_type or "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if etag:
        headers["If-Match"] = f'"{etag.strip(chr(34))}"'
    if method == "GET":
        headers["Accept"] = content_type or "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return response.read().decode(), dict(response.headers)
    except urllib.error.HTTPError as err:
        detail = err.read().decode(errors="replace").strip()
        try:
            parsed = json.loads(detail)
            detail = parsed.get("message") or parsed.get("error") or detail
        except ValueError:
            pass
        if err.code == 401:
            raise ApiError("Unauthorized: check the credential") from err
        if err.code == 403:
            raise ApiError("Forbidden: the credential needs the policy_file scope") from err
        if err.code == 412:
            raise ApiError("The policy changed while this ran; nothing was written. Try again.") from err
        raise ApiError(f"HTTP {err.code}: {detail}") from err
    except urllib.error.URLError as err:
        raise ApiError(f"Could not reach the Tailscale API: {err.reason}") from err


def access_token(credential: str, client_id: str = "") -> str:
    """API keys are bearer tokens; OAuth client secrets are exchanged first."""
    if credential.startswith("tskey-api-"):
        return credential
    form = {"client_secret": credential}
    if client_id:
        form["client_id"] = client_id
    body, _ = request("POST", f"{API}/api/v2/oauth/token", form=form)
    token = json.loads(body).get("access_token")
    if not token:
        raise ApiError("The OAuth response contained no access token")
    return token


def get_policy(token: str, tailnet: str) -> tuple[str, str]:
    url = f"{API}/api/v2/tailnet/{urllib.parse.quote(tailnet, safe='')}/acl"
    body, headers = request("GET", url, token=token, content_type="application/hujson")
    return body, headers.get("ETag", "")


def validate_policy(token: str, tailnet: str, text: str) -> None:
    url = f"{API}/api/v2/tailnet/{urllib.parse.quote(tailnet, safe='')}/acl/validate"
    request("POST", url, token=token, body=text, content_type="application/hujson")


def put_policy(token: str, tailnet: str, text: str, etag: str) -> None:
    url = f"{API}/api/v2/tailnet/{urllib.parse.quote(tailnet, safe='')}/acl"
    request("POST", url, token=token, body=text, content_type="application/hujson", etag=etag)


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

def run(args) -> int:
    src = [x for x in args.src.split(",") if x]
    dst = [x for x in args.dst.split(",") if x]
    if not src or not dst:
        print("A source and destination are required.", file=sys.stderr)
        return 2

    token = access_token(args.credential, args.client_id)
    current, etag = get_policy(token, args.tailnet)

    try:
        policy = parse(current)
    except ValueError as err:
        raise ApiError(f"Could not read the current policy file: {err}") from err

    if has_grant(policy, src, dst, args.port, args.capability):
        print("The tailnet already grants this capability. Nothing to change.")
        return 0

    grant = build_grant(src, dst, args.port, args.capability)
    try:
        proposed = insert_grant(current, grant)
    except ValueError as err:
        print(f"Cannot edit this policy file safely: {err}\n", file=sys.stderr)
        print("Add this grant by hand in the admin console:\n", file=sys.stderr)
        print(json.dumps(grant, indent=2), file=sys.stderr)
        return 3

    print(diff(current, proposed) or "(no textual change)")

    validate_policy(token, args.tailnet, proposed)
    print("\n[✓] Tailscale validated the proposed policy.")

    if args.dry_run:
        print("\nDry run: nothing was written.")
        return 0

    if args.confirm != args.tailnet:
        print("\nNot confirmed; nothing was written.", file=sys.stderr)
        return 4

    put_policy(token, args.tailnet, proposed, etag)

    verify, _ = get_policy(token, args.tailnet)
    if not has_grant(parse(verify), src, dst, args.port, args.capability):
        raise ApiError("The policy was written but the grant is not visible; check the admin console")
    print("[✓] Grant applied and verified.")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tailnet", default="-")
    parser.add_argument("--credential", default="",
                        help=f"prefer the {CREDENTIAL_ENV} environment variable")
    parser.add_argument("--client-id", default="")
    parser.add_argument("--src", required=True, help="comma-separated grant sources")
    parser.add_argument("--dst", required=True, help="comma-separated grant destinations")
    parser.add_argument("--port", type=int, default=8443)
    parser.add_argument("--capability", default="interstellarnetwork.nl/cap/server-control")
    parser.add_argument("--confirm", default="", help="must equal --tailnet to write")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    args.credential = os.environ.get(CREDENTIAL_ENV) or args.credential
    if not args.credential:
        print(f"No credential supplied; set {CREDENTIAL_ENV}.", file=sys.stderr)
        return 2
    try:
        return run(args)
    except ApiError as err:
        print(f"{err}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
