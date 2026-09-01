from collections import Counter
import json
from pathlib import Path
import tempfile
import unittest

from tools.coco80.assets import sha256_file
from tools.coco80.conformance import (
    CONFORMANCE_COUNT,
    _greedy_select,
    _list_sha256,
    aspect_bucket,
    build_conformance_binary,
    parse_conformance_binary,
)
from tools.coco80.sd_pack import HEADER_BYTES, _write_input_binary_index


class ConformanceSelectionTest(unittest.TestCase):
    def test_aspect_buckets(self):
        self.assertEqual(aspect_bucket(300, 100), "wide")
        self.assertEqual(aspect_bucket(100, 300), "tall")
        self.assertEqual(aspect_bucket(100, 100), "square")
        with self.assertRaises(ValueError):
            aspect_bucket(0, 10)

    def test_seeded_selection_is_unique_deterministic_and_covers(self):
        coverage = {}
        ids = []
        image_id = 1
        for class_index in range(80):
            for size in ("small", "medium", "large"):
                coverage[image_id] = {(class_index, size)}
                ids.append(image_id)
                image_id += 1
        # The synthetic fixture needs 240 records to cover 240 independent
        # strata; this exercises the full-coverage failure and success gates.
        with self.assertRaisesRegex(RuntimeError, "strata uncovered"):
            _greedy_select(ids, coverage, 128, 20260814, [], require_full=True)
        first = _greedy_select(ids, coverage, 240, 20260814, [], require_full=True)
        second = _greedy_select(ids, coverage, 240, 20260814, [], require_full=True)
        self.assertEqual(first, second)
        self.assertEqual(len(first), len(set(first)))
        represented = Counter(value for image_id in first for value in coverage[image_id])
        self.assertEqual(len(represented), 240)

    def test_binary_selection_binds_manifest_and_dense_input_index(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            selection_path = root / "selection.json"
            input_index = root / "input_index.bin"
            output = root / "conformance_index.bin"
            image_ids = list(range(1001, 1001 + CONFORMANCE_COUNT))
            selection = {
                "format": "kv260-coco80-board-conformance-selection",
                "version": 1,
                "conformance": {
                    "count": CONFORMANCE_COUNT,
                    "image_id_list_sha256": _list_sha256(image_ids),
                    "images": [{"image_id": value} for value in reversed(image_ids)],
                },
            }
            reversed_ids = list(reversed(image_ids))
            selection["conformance"]["image_id_list_sha256"] = _list_sha256(reversed_ids)
            selection_path.write_text(json.dumps(selection), encoding="utf-8")
            entries = []
            for record, image_id in enumerate(image_ids):
                entries.append({
                    "image_id": image_id,
                    "record_index": record,
                    "shard_id": 0,
                    "offset": record * HEADER_BYTES,
                    "package": {"total_bytes": HEADER_BYTES, "package_crc32": record + 1},
                    "letterbox": {"source_width": 640, "source_height": 480},
                })
            _write_input_binary_index(
                input_index,
                [{
                    "shard_id": 0,
                    "first_record": 0,
                    "record_count": CONFORMANCE_COUNT,
                    "bytes": CONFORMANCE_COUNT * HEADER_BYTES,
                    "crc32": 1,
                    "path": "in_0000.bin",
                    "sha256": "11" * 32,
                }],
                entries,
                "22" * 32,
            )
            built = build_conformance_binary(selection_path, input_index, output)
            self.assertEqual(built["count"], CONFORMANCE_COUNT)
            self.assertEqual(built["records"][0], {
                "image_id": reversed_ids[0], "record_index": CONFORMANCE_COUNT - 1
            })
            self.assertEqual(built["selection_manifest_sha256"], sha256_file(selection_path))
            self.assertEqual(parse_conformance_binary(output, input_index)["records"], built["records"])
            damaged = bytearray(output.read_bytes())
            damaged[-1] ^= 1
            output.write_bytes(damaged)
            with self.assertRaisesRegex(RuntimeError, "CRC32"):
                parse_conformance_binary(output, input_index)


if __name__ == "__main__":
    unittest.main()
