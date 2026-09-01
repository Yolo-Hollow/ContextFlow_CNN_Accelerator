import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from tools.coco80.assets import (
    AssetValidationError,
    build_manifest,
    load_manifest,
    sha256_file,
    verify_manifest,
    write_manifest_atomic,
)


class AssetManifestTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="coco80_assets_")
        self.root = Path(self.temp.name)
        (self.root / "nested").mkdir()
        self.a = self.root / "a.bin"
        self.b = self.root / "nested" / "b.json"
        self.a.write_bytes(b"alpha")
        self.b.write_text('{"value": 2}\n', encoding="utf-8")
        self.manifest_path = self.root / "assets.manifest.json"

    def tearDown(self):
        self.temp.cleanup()

    def test_sha256_and_deterministic_atomic_manifest(self):
        self.assertEqual(sha256_file(self.a), hashlib.sha256(b"alpha").hexdigest())
        manifest = build_manifest(
            self.root,
            [self.b, "a.bin"],
            metadata={"purpose": "unit-test"},
        )
        self.assertEqual([entry.path for entry in manifest.files], ["a.bin", "nested/b.json"])

        write_manifest_atomic(self.manifest_path, manifest)
        first = self.manifest_path.read_bytes()
        write_manifest_atomic(self.manifest_path, manifest)
        self.assertEqual(self.manifest_path.read_bytes(), first)
        self.assertEqual(load_manifest(self.manifest_path), manifest)
        self.assertEqual(
            verify_manifest(
                self.manifest_path,
                required_paths=["a.bin", "nested/b.json"],
            ),
            (self.a.resolve(), self.b.resolve()),
        )
        self.assertEqual(list(self.root.glob(".assets.manifest.json.*.tmp")), [])

    def test_changed_content_fails_even_when_size_is_unchanged(self):
        manifest = build_manifest(self.root, [self.a])
        self.a.write_bytes(b"alpHa")
        with self.assertRaisesRegex(AssetValidationError, "SHA256 mismatch"):
            verify_manifest(manifest, root=self.root)

    def test_missing_and_unmanifested_required_assets_fail_closed(self):
        manifest = build_manifest(self.root, [self.a])
        self.a.unlink()
        with self.assertRaisesRegex(AssetValidationError, "missing"):
            verify_manifest(manifest, root=self.root)

        manifest = build_manifest(self.root, [self.b])
        with self.assertRaisesRegex(AssetValidationError, "absent from manifest"):
            verify_manifest(manifest, root=self.root, required_paths=["a.bin"])

    def test_malformed_or_traversing_manifest_is_rejected(self):
        bad = {
            "schema": "coco80.assets.v1",
            "files": [
                {"path": "../escape.bin", "size_bytes": 1, "sha256": "0" * 64}
            ],
            "metadata": {},
        }
        self.manifest_path.write_text(json.dumps(bad), encoding="utf-8")
        with self.assertRaisesRegex(AssetValidationError, "normalized and relative"):
            load_manifest(self.manifest_path)

        bad["files"][0]["path"] = "a.bin"
        bad["files"][0]["sha256"] = "NOT-A-HASH"
        self.manifest_path.write_text(json.dumps(bad), encoding="utf-8")
        with self.assertRaisesRegex(AssetValidationError, "lowercase hexadecimal"):
            load_manifest(self.manifest_path)

    def test_symlink_asset_is_rejected_when_platform_allows_creation(self):
        link = self.root / "link.bin"
        try:
            link.symlink_to(self.a)
        except OSError:
            self.skipTest("symlink creation is unavailable")
        with self.assertRaisesRegex(AssetValidationError, "symlink"):
            build_manifest(self.root, [link])


if __name__ == "__main__":
    unittest.main()
