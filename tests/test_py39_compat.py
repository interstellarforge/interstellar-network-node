"""Python 3.9 compatibility guard for every runtime source in this repository.

A `zip(first, second, strict=False)` reached a Debian 11 / Python 3.9 LXC
container and took out `/health` and `/stats` with
`TypeError: zip() takes no keyword arguments`, while `/` kept working and the
service stayed `active`. The agent starts because `from __future__ import
annotations` defers the 3.10-only `X | None` annotations, so nothing fails until
a request actually runs the collector.

These tests parse and inspect every runtime source, including the Python that is
embedded into the Toolbox shell script, so a post-3.9 construct fails CI rather
than a customer's container.
"""
from __future__ import annotations

import ast
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]
BOX = ROOT / "toolbox/interstellar-network-toolbox.sh"
MINIMUM = (3, 9)

# Names that make a `X | Y` expression a PEP 604 type union rather than arithmetic.
TYPE_NAMES = {"int", "str", "float", "bool", "bytes", "list", "dict", "set", "tuple",
              "frozenset", "Any", "object", "Path", "datetime"}

POST_39_FROM_IMPORTS = {
    ("typing", "Self"): "3.11", ("typing", "Never"): "3.11",
    ("typing", "LiteralString"): "3.11", ("typing", "assert_type"): "3.11",
    ("typing", "override"): "3.12", ("typing", "TypeAlias"): "3.10",
    ("typing", "ParamSpec"): "3.10", ("typing", "TypeGuard"): "3.10",
    ("typing", "Concatenate"): "3.10", ("itertools", "pairwise"): "3.10",
    ("contextlib", "chdir"): "3.11", ("datetime", "UTC"): "3.11",
    ("enum", "StrEnum"): "3.11", ("enum", "ReprEnum"): "3.11",
    ("hashlib", "file_digest"): "3.11", ("asyncio", "TaskGroup"): "3.11",
}
POST_39_MODULES = {"tomllib": "3.11"}
POST_39_ATTRS = {"bit_count": "3.10", "pairwise": "3.10", "file_digest": "3.11"}


def runtime_sources() -> list[tuple[str, str]]:
    """Every Python source that ships to a node, standalone or embedded."""
    sources: list[tuple[str, str]] = []
    for path in sorted(ROOT.glob("control/*.py")) + sorted(ROOT.glob("toolbox/*.py")):
        sources.append((str(path.relative_to(ROOT)), path.read_text()))
    box = BOX.read_text()
    for index, block in enumerate(re.findall(r"<<'PYEOF'\n(.*?)\nPYEOF", box, re.S)):
        sources.append((f"toolbox.sh heredoc[{index}]", block))
    for index, block in enumerate(re.findall(r"python3 -c '(.*?)'", box, re.S)):
        sources.append((f"toolbox.sh inline[{index}]", block))
    return sources


def has_future_annotations(tree: ast.Module) -> bool:
    return any(isinstance(node, ast.ImportFrom) and node.module == "__future__"
               and any(alias.name == "annotations" for alias in node.names)
               for node in tree.body)


def annotation_node_ids(tree: ast.Module) -> set[int]:
    """Ids of nodes sitting inside an annotation, which `from __future__` defers."""
    annotations: list[ast.AST] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.AnnAssign) and node.annotation is not None:
            annotations.append(node.annotation)
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            if node.returns is not None:
                annotations.append(node.returns)
            args = node.args
            for arg in [*args.posonlyargs, *args.args, *args.kwonlyargs,
                        args.vararg, args.kwarg]:
                if arg is not None and arg.annotation is not None:
                    annotations.append(arg.annotation)
    ids: set[int] = set()
    for annotation in annotations:
        for node in ast.walk(annotation):
            ids.add(id(node))
    return ids


def is_type_union(node: ast.AST) -> bool:
    if not isinstance(node, ast.BinOp) or not isinstance(node.op, ast.BitOr):
        return False
    for side in (node.left, node.right):
        if isinstance(side, ast.Constant) and side.value is None:
            return True
        if isinstance(side, ast.Name) and side.id in TYPE_NAMES:
            return True
        if isinstance(side, ast.Subscript):
            return True
    return False


class SyntaxTests(unittest.TestCase):
    def test_sources_were_found(self):
        """A silent extraction failure would make every other test vacuous."""
        labels = [label for label, _ in runtime_sources()]
        self.assertGreaterEqual(len(labels), 12, labels)
        self.assertTrue(any("control_api.py" in label for label in labels))
        self.assertTrue(any("heredoc" in label for label in labels))

    def test_every_runtime_source_parses_on_python_39(self):
        for label, source in runtime_sources():
            with self.subTest(source=label):
                try:
                    ast.parse(source, feature_version=MINIMUM)
                except SyntaxError as err:
                    self.fail(f"{label} is not valid Python 3.9: {err.msg} (line {err.lineno})")


class RuntimeFeatureTests(unittest.TestCase):
    def test_no_zip_strict_keyword(self):
        """The exact regression: zip(strict=) is 3.10+ and needlessly used."""
        for label, source in runtime_sources():
            for node in ast.walk(ast.parse(source)):
                if not isinstance(node, ast.Call):
                    continue
                name = getattr(node.func, "id", None) or getattr(node.func, "attr", None)
                if name != "zip":
                    continue
                for keyword in node.keywords:
                    self.assertNotEqual(
                        "strict", keyword.arg,
                        f"{label} line {node.lineno}: zip(strict=) requires Python 3.10")

    def test_no_post_39_imports(self):
        for label, source in runtime_sources():
            for node in ast.walk(ast.parse(source)):
                if isinstance(node, ast.Import):
                    for alias in node.names:
                        self.assertNotIn(
                            alias.name, POST_39_MODULES,
                            f"{label} line {node.lineno}: {alias.name} is newer than 3.9")
                elif isinstance(node, ast.ImportFrom):
                    for alias in node.names:
                        key = (node.module, alias.name)
                        self.assertNotIn(
                            key, POST_39_FROM_IMPORTS,
                            f"{label} line {node.lineno}: {node.module}.{alias.name} "
                            f"needs {POST_39_FROM_IMPORTS.get(key)}")

    def test_no_post_39_attributes(self):
        for label, source in runtime_sources():
            for node in ast.walk(ast.parse(source)):
                if isinstance(node, ast.Attribute):
                    self.assertNotIn(
                        node.attr, POST_39_ATTRS,
                        f"{label} line {node.lineno}: .{node.attr} needs "
                        f"{POST_39_ATTRS.get(node.attr)}")

    def test_pep604_unions_are_never_evaluated_at_runtime(self):
        """`X | None` is fine as a deferred annotation and fatal anywhere else.

        Without `from __future__ import annotations` the union is evaluated when
        the module is imported, so the agent would not start at all on 3.9.
        """
        for label, source in runtime_sources():
            tree = ast.parse(source)
            deferred = has_future_annotations(tree)
            in_annotation = annotation_node_ids(tree)
            for node in ast.walk(tree):
                if not is_type_union(node):
                    continue
                if id(node) in in_annotation:
                    self.assertTrue(
                        deferred,
                        f"{label} line {node.lineno}: PEP 604 union in an annotation "
                        "without `from __future__ import annotations`")
                else:
                    self.fail(f"{label} line {node.lineno}: PEP 604 union outside an "
                              "annotation is evaluated on 3.9")


class TimestampTests(unittest.TestCase):
    """3.9's fromisoformat rejects a trailing `Z`; only `+00:00` is portable."""

    def test_helper_timestamps_are_parseable_on_39(self):
        from datetime import datetime, timezone
        produced = datetime.now(timezone.utc).isoformat()
        self.assertTrue(produced.endswith("+00:00"), produced)
        self.assertIsNotNone(datetime.fromisoformat(produced))

    def test_runtime_sources_use_isoformat_offsets_not_z(self):
        """Every timestamp is `.isoformat()`, which yields a 3.9-parseable offset.

        Nothing may hand-build a `Z` suffix, because the control helper feeds its
        own stored timestamps back through fromisoformat to compute reboot
        duration, and 3.9 rejects `Z` there.
        """
        for label, source in runtime_sources():
            with self.subTest(source=label):
                self.assertNotIn('+ "Z"', source, f"{label} builds a Z suffix by hand")
                self.assertNotIn('"Z"', source, f"{label} references a literal Z suffix")

    def test_control_helper_round_trips_its_own_timestamps(self):
        """The one fromisoformat caller must parse what utcnow() produces."""
        from datetime import datetime, timezone
        helper = (ROOT / "control/control_helper.py").read_text()
        self.assertIn("fromisoformat", helper)
        self.assertIn("return datetime.now(timezone.utc).isoformat()", helper)
        produced = datetime.now(timezone.utc).isoformat()
        self.assertIsNotNone(datetime.fromisoformat(produced))


if __name__ == "__main__":
    unittest.main()
