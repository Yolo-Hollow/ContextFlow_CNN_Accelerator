"""Fast fail-closed tests for the portable XSIM fixture manifest."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from prepare_xsim_fixtures import SCHEMA_VERSION, validate_manifest
from xsim_fixture_lib import ensure_under, sha256_file, source_fingerprint


class XsimFixtureManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        repo_root = Path(__file__).resolve().parent.parent
        scratch_root = repo_root / "build_xsim"
        scratch_root.mkdir(exist_ok=True)
        self._temporary = tempfile.TemporaryDirectory(
            prefix="fixture_unittest_", dir=scratch_root
        )
        self.root = Path(self._temporary.name)
        self.source = self.root / "repro" / "source.bin"
        self.output = self.root / "fixtures" / "output.mem"
        self.manifest = self.root / "fixtures" / "fixture_manifest.json"
        self.source.parent.mkdir(parents=True)
        self.output.parent.mkdir(parents=True)
        self.source.write_bytes(b"tracked-source")
        self.output.write_bytes(b"00\n01\n")
        payload = {
            "schema_version": SCHEMA_VERSION,
            "sources": source_fingerprint([self.source], self.root),
            "outputs": [
                {
                    "path": self.output.relative_to(self.root).as_posix(),
                    "bytes": self.output.stat().st_size,
                    "sha256": sha256_file(self.output),
                }
            ],
        }
        self.manifest.write_text(json.dumps(payload), encoding="utf-8")

    def tearDown(self) -> None:
        self._temporary.cleanup()

    def test_valid_manifest_and_hashes_pass(self) -> None:
        valid, reason = validate_manifest(
            self.manifest, self.root, [self.source], [self.output]
        )
        self.assertTrue(valid, reason)

    def test_output_tamper_with_same_size_fails_closed(self) -> None:
        self.output.write_bytes(b"ff\n01\n")
        valid, reason = validate_manifest(
            self.manifest, self.root, [self.source], [self.output]
        )
        self.assertFalse(valid)
        self.assertIn("hash mismatch", reason)

    def test_source_tamper_fails_closed(self) -> None:
        self.source.write_bytes(b"changed-source")
        valid, reason = validate_manifest(
            self.manifest, self.root, [self.source], [self.output]
        )
        self.assertFalse(valid)
        self.assertIn("source fingerprint changed", reason)

    def test_extra_manifest_output_fails_closed(self) -> None:
        payload = json.loads(self.manifest.read_text(encoding="utf-8"))
        payload["outputs"].append(
            {
                "path": "fixtures/unexpected.mem",
                "bytes": 0,
                "sha256": sha256_file(self.output),
            }
        )
        self.manifest.write_text(json.dumps(payload), encoding="utf-8")
        valid, reason = validate_manifest(
            self.manifest, self.root, [self.source], [self.output]
        )
        self.assertFalse(valid)
        self.assertIn("output set changed", reason)

    def test_source_path_cannot_escape_repro(self) -> None:
        repro_root = self.root / "repro"
        outside = self.root / "outside.bin"
        outside.write_bytes(b"outside")
        with self.assertRaisesRegex(RuntimeError, "escapes repository repro"):
            ensure_under(outside, repro_root)


if __name__ == "__main__":
    unittest.main()
