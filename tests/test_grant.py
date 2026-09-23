"""Tailnet Grant automation.

The policy file is HuJSON and often carries the operator's own comments. The
grant is therefore inserted textually; anything that would rewrite or reformat
the rest of the file is a defect. These tests pin that behaviour, plus the
idempotency and fail-closed rules.
"""
from __future__ import annotations

import http.server
import importlib.util
import json
import os
import re
import subprocess
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]
_spec = importlib.util.spec_from_file_location("tailnet_grant", ROOT / "toolbox/tailnet-grant.py")
grant = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(grant)

CAPABILITY = "interstellarnetwork.nl/cap/server-control"
SRC = ["tag:home-assistant"]
DST = ["tag:interstellar-server"]

COMMENTED_POLICY = """\
// Tailnet policy for example.com
// Keep this file tidy; every rule needs a reason.
{
  "tagOwners": {
    "tag:home-assistant":     ["autogroup:admin"],  // HA runs on the NUC
    "tag:interstellar-server": ["autogroup:admin"],
  },

  /* Grants replaced the old acls block in 2026. */
  "grants": [
    // Everyone may reach the health plane.
    {
      "src": ["autogroup:member"],
      "dst": ["tag:interstellar-server"],
      "ip":  ["tcp:443"],
    },
  ],

  "ssh": [
    {
      "action": "check",
      "src":    ["autogroup:member"],
      "dst":    ["autogroup:self"],
      "users":  ["autogroup:nonroot"],
    },
  ],
}
"""


class HujsonTests(unittest.TestCase):
    def test_comments_and_trailing_commas_parse(self):
        policy = grant.parse(COMMENTED_POLICY)
        self.assertIn("tagOwners", policy)
        self.assertEqual(1, len(policy["grants"]))
        self.assertEqual(["tcp:443"], policy["grants"][0]["ip"])

    def test_slashes_inside_strings_are_not_comments(self):
        text = '{"grants": [{"app": {"example.com/cap/x": [{}]}}], "note": "http://a//b"}'
        policy = grant.parse(text)
        self.assertEqual("http://a//b", policy["note"])
        self.assertIn("example.com/cap/x", policy["grants"][0]["app"])

    def test_braces_inside_comments_do_not_shift_structure(self):
        text = '{\n  // a stray { and ] in a comment\n  "grants": [\n  ],\n}\n'
        self.assertIsNotNone(grant.find_top_level_array(text, "grants"))
        self.assertEqual({"grants": []}, grant.parse(text))

    def test_escaped_quote_in_string(self):
        text = '{"note": "she said \\"hi\\" // not a comment", "grants": []}'
        self.assertEqual('she said "hi" // not a comment', grant.parse(text)["note"])

    def test_nested_grants_key_is_ignored(self):
        """Only a depth-1 "grants" is the real one."""
        text = '{\n  "tests": [\n    {"grants": ["decoy"]}\n  ],\n  "grants": [\n  ],\n}\n'
        position = grant.find_top_level_array(text, "grants")
        self.assertIsNotNone(position)
        # The located bracket must be the second one, not the decoy.
        self.assertGreater(position, text.index('"tests"'))
        self.assertGreater(position, text.index('{"grants": ["decoy"]}'))


class InsertionTests(unittest.TestCase):
    def apply(self, text):
        return grant.insert_grant(text, grant.build_grant(SRC, DST, 8443, CAPABILITY))

    def test_every_comment_survives(self):
        result = self.apply(COMMENTED_POLICY)
        for comment in ("// Tailnet policy for example.com",
                        "// Keep this file tidy; every rule needs a reason.",
                        "// HA runs on the NUC",
                        "/* Grants replaced the old acls block in 2026. */",
                        "// Everyone may reach the health plane."):
            self.assertIn(comment, result, f"lost comment: {comment}")

    def test_unrelated_sections_are_untouched(self):
        result = self.apply(COMMENTED_POLICY)
        for block in ('"tagOwners"', '"ssh"', '"action": "check"',
                      '"tag:home-assistant":     ["autogroup:admin"]'):
            self.assertIn(block, result)
        # The existing health grant keeps its formatting and trailing comma.
        self.assertIn('      "ip":  ["tcp:443"],\n', result)

    def test_result_is_valid_hujson_with_both_grants(self):
        policy = grant.parse(self.apply(COMMENTED_POLICY))
        self.assertEqual(2, len(policy["grants"]))
        self.assertTrue(grant.has_grant(policy, SRC, DST, 8443, CAPABILITY))
        # The pre-existing grant is still there and unchanged.
        self.assertIn({"src": ["autogroup:member"], "dst": ["tag:interstellar-server"],
                       "ip": ["tcp:443"]}, policy["grants"])

    def test_new_grant_has_the_expected_shape(self):
        policy = grant.parse(self.apply(COMMENTED_POLICY))
        added = next(g for g in policy["grants"] if "app" in g)
        self.assertEqual({"src": SRC, "dst": DST, "ip": ["tcp:8443"],
                          "app": {CAPABILITY: [{}]}}, added)

    def test_policy_without_a_grants_key_gains_one(self):
        text = '{\n  // only acls here\n  "acls": [\n    {"action": "accept", "src": ["*"], "dst": ["*:*"]},\n  ],\n}\n'
        result = self.apply(text)
        policy = grant.parse(result)
        self.assertIn("// only acls here", result)
        self.assertEqual(1, len(policy["acls"]))
        self.assertTrue(grant.has_grant(policy, SRC, DST, 8443, CAPABILITY))

    def test_empty_grants_array_on_one_line(self):
        policy = grant.parse(self.apply('{"grants": [], "acls": []}'))
        self.assertTrue(grant.has_grant(policy, SRC, DST, 8443, CAPABILITY))
        self.assertEqual([], policy["acls"])

    def test_refuses_when_grants_is_not_an_array_literal(self):
        """Fail closed rather than guess at an insertion point."""
        with self.assertRaises(ValueError):
            self.apply('{\n  "grants": null,\n}\n')

    def test_refuses_a_non_object_policy(self):
        with self.assertRaises(ValueError):
            self.apply('[1, 2, 3]\n')

    def test_diff_is_addition_only(self):
        before = COMMENTED_POLICY
        after = self.apply(before)
        removed = [line for line in grant.diff(before, after).splitlines()
                   if line.startswith("-") and not line.startswith("---")]
        self.assertEqual([], removed, "the grant insertion must not remove any line")


class IdempotencyTests(unittest.TestCase):
    def test_existing_identical_grant_is_detected(self):
        policy = grant.parse(grant.insert_grant(
            COMMENTED_POLICY, grant.build_grant(SRC, DST, 8443, CAPABILITY)))
        self.assertTrue(grant.has_grant(policy, SRC, DST, 8443, CAPABILITY))

    def test_broader_existing_grant_counts(self):
        policy = {"grants": [{"src": ["tag:home-assistant", "tag:other"],
                              "dst": ["tag:interstellar-server", "tag:more"],
                              "ip": ["tcp:8443", "tcp:443"],
                              "app": {CAPABILITY: [{}]}}]}
        self.assertTrue(grant.has_grant(policy, SRC, DST, 8443, CAPABILITY))

    def test_grant_without_ip_restriction_counts(self):
        policy = {"grants": [{"src": SRC, "dst": DST, "app": {CAPABILITY: [{}]}}]}
        self.assertTrue(grant.has_grant(policy, SRC, DST, 8443, CAPABILITY))

    def test_wrong_port_does_not_count(self):
        policy = {"grants": [{"src": SRC, "dst": DST, "ip": ["tcp:443"],
                              "app": {CAPABILITY: [{}]}}]}
        self.assertFalse(grant.has_grant(policy, SRC, DST, 8443, CAPABILITY))

    def test_wrong_source_does_not_count(self):
        policy = {"grants": [{"src": ["tag:someone-else"], "dst": DST, "ip": ["tcp:8443"],
                              "app": {CAPABILITY: [{}]}}]}
        self.assertFalse(grant.has_grant(policy, SRC, DST, 8443, CAPABILITY))

    def test_network_only_grant_does_not_count(self):
        """Port access without the app capability still yields HTTP 403."""
        policy = {"grants": [{"src": SRC, "dst": DST, "ip": ["tcp:8443"]}]}
        self.assertFalse(grant.has_grant(policy, SRC, DST, 8443, CAPABILITY))

    def test_missing_grants_key(self):
        self.assertFalse(grant.has_grant({"acls": []}, SRC, DST, 8443, CAPABILITY))


class ApiPlumbingTests(unittest.TestCase):
    def test_api_key_is_used_directly(self):
        self.assertEqual("tskey-api-abc", grant.access_token("tskey-api-abc"))

    def test_etag_is_quoted_for_if_match(self):
        captured = {}

        def fake(url, timeout=None):  # pragma: no cover - exercised below
            raise AssertionError("not reached")

        original = grant.urllib.request.Request

        def capture(url, data=None, headers=None, method=None):
            captured.update(headers or {})
            return original(url, data=data, headers=headers or {}, method=method)

        grant.urllib.request.Request = capture
        try:
            with self.assertRaises(Exception):
                grant.request("POST", "http://127.0.0.1:1/acl", token="t",
                              body="{}", content_type="application/hujson", etag="abc123")
        finally:
            grant.urllib.request.Request = original
        self.assertEqual('"abc123"', captured.get("If-Match"))
        self.assertEqual("Bearer t", captured.get("Authorization"))

    def test_already_quoted_etag_is_not_double_quoted(self):
        captured = {}
        original = grant.urllib.request.Request

        def capture(url, data=None, headers=None, method=None):
            captured.update(headers or {})
            return original(url, data=data, headers=headers or {}, method=method)

        grant.urllib.request.Request = capture
        try:
            with self.assertRaises(Exception):
                grant.request("POST", "http://127.0.0.1:1/acl", token="t", body="{}", etag='"abc123"')
        finally:
            grant.urllib.request.Request = original
        self.assertEqual('"abc123"', captured.get("If-Match"))


class FakeTailscaleApi(http.server.BaseHTTPRequestHandler):
    """Minimal stand-in for the policy-file endpoints."""

    policy = COMMENTED_POLICY
    etag = "etag-1"
    writes: list = []
    validations: list = []
    fail_precondition = False

    def log_message(self, *args):
        pass

    def reply(self, status, body="", headers=None):
        payload = body.encode()
        self.send_response(status)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path.endswith("/acl"):
            self.reply(200, type(self).policy, {"ETag": f'"{type(self).etag}"'})
        else:
            self.reply(404, "{}")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode()
        if self.path.endswith("/oauth/token"):
            self.reply(200, json.dumps({"access_token": "tskey-api-exchanged"}))
        elif self.path.endswith("/acl/validate"):
            type(self).validations.append(body)
            self.reply(200, "{}")
        elif self.path.endswith("/acl"):
            if type(self).fail_precondition:
                self.reply(412, json.dumps({"message": "etag mismatch"}))
                return
            if self.headers.get("If-Match") != f'"{type(self).etag}"':
                self.reply(412, json.dumps({"message": "missing If-Match"}))
                return
            type(self).writes.append(body)
            type(self).policy = body
            self.reply(200, "{}")
        else:
            self.reply(404, "{}")


class EndToEndTests(unittest.TestCase):
    """Drives the real embedded Toolbox shell function against a fake API."""

    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeTailscaleApi)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"
        toolbox = (ROOT / "toolbox/interstellar-network-toolbox.sh").read_text()
        match = re.search(r"^run_tailnet_grant\(\) \{.*?^\}$", toolbox, re.S | re.M)
        assert match, "run_tailnet_grant is not embedded; run scripts/embed-control.py"
        cls.function = match.group(0)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        FakeTailscaleApi.policy = COMMENTED_POLICY
        FakeTailscaleApi.etag = "etag-1"
        FakeTailscaleApi.writes = []
        FakeTailscaleApi.validations = []
        FakeTailscaleApi.fail_precondition = False

    def run_tool(self, *args, credential="tskey-api-test"):
        script = f'{self.function}\nrun_tailnet_grant "$@"\n'
        return subprocess.run(
            ["bash", "-c", script, "bash", *args], capture_output=True, text=True,
            env={**os.environ, "TS_GRANT_API": self.base, "TS_GRANT_CREDENTIAL": credential})

    def base_args(self, *extra):
        return ("--tailnet", "example.com", "--src", "tag:home-assistant",
                "--dst", "tag:interstellar-server", "--port", "8443",
                "--capability", CAPABILITY, *extra)

    def test_dry_run_shows_diff_validates_and_writes_nothing(self):
        result = self.run_tool(*self.base_args("--dry-run"))
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("+++ proposed policy", result.stdout)
        self.assertIn(CAPABILITY, result.stdout)
        self.assertIn("Tailscale validated", result.stdout)
        self.assertIn("nothing was written", result.stdout)
        self.assertEqual(1, len(FakeTailscaleApi.validations), "must validate before offering to write")
        self.assertEqual([], FakeTailscaleApi.writes)

    def test_without_confirmation_nothing_is_written(self):
        result = self.run_tool(*self.base_args())
        self.assertNotEqual(0, result.returncode)
        self.assertIn("Not confirmed", result.stderr)
        self.assertEqual([], FakeTailscaleApi.writes)

    def test_wrong_confirmation_is_rejected(self):
        result = self.run_tool(*self.base_args("--confirm", "wrong-tailnet"))
        self.assertNotEqual(0, result.returncode)
        self.assertEqual([], FakeTailscaleApi.writes)

    def test_confirmed_run_applies_and_verifies(self):
        result = self.run_tool(*self.base_args("--confirm", "example.com"))
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("applied and verified", result.stdout)
        self.assertEqual(1, len(FakeTailscaleApi.writes))
        written = FakeTailscaleApi.writes[0]
        self.assertTrue(grant.has_grant(grant.parse(written), SRC, DST, 8443, CAPABILITY))
        self.assertIn("// Keep this file tidy; every rule needs a reason.", written)

    def test_second_run_is_a_no_op(self):
        self.run_tool(*self.base_args("--confirm", "example.com"))
        FakeTailscaleApi.writes = []
        result = self.run_tool(*self.base_args("--confirm", "example.com"))
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("already grants this capability", result.stdout)
        self.assertEqual([], FakeTailscaleApi.writes)

    def test_concurrent_edit_aborts_instead_of_overwriting(self):
        FakeTailscaleApi.fail_precondition = True
        result = self.run_tool(*self.base_args("--confirm", "example.com"))
        self.assertNotEqual(0, result.returncode)
        self.assertIn("policy changed while this ran", result.stderr)
        self.assertEqual([], FakeTailscaleApi.writes)

    def test_oauth_secret_is_exchanged_for_a_token(self):
        result = self.run_tool(*self.base_args("--dry-run"), credential="tskey-client-abc-secret")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("+++ proposed policy", result.stdout)

    def test_missing_credential_fails_closed(self):
        result = self.run_tool(*self.base_args("--dry-run"), credential="")
        self.assertNotEqual(0, result.returncode)
        self.assertIn("No credential supplied", result.stderr)
        self.assertEqual([], FakeTailscaleApi.writes)

    def test_credential_never_appears_in_argv(self):
        """The Toolbox passes it by environment; /proc/<pid>/cmdline is world readable."""
        toolbox = (ROOT / "toolbox/interstellar-network-toolbox.sh").read_text()
        match = re.search(r"^control_configure_grant\(\) \{.*?^\}$", toolbox, re.S | re.M)
        self.assertIsNotNone(match)
        body = match.group(0)
        self.assertIn("TS_GRANT_CREDENTIAL=", body)
        self.assertNotIn("--credential", body)

    def test_unparseable_policy_fails_closed_with_the_snippet(self):
        FakeTailscaleApi.policy = '{\n  "grants": null,\n}\n'
        result = self.run_tool(*self.base_args("--confirm", "example.com"))
        self.assertNotEqual(0, result.returncode)
        self.assertIn("Cannot edit this policy file safely", result.stderr)
        self.assertIn(CAPABILITY, result.stderr)
        self.assertEqual([], FakeTailscaleApi.writes)


if __name__ == "__main__":
    unittest.main()
