from __future__ import annotations

import hashlib
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

from tools.coco80.sd_deploy import (
    prepare_card,
    register_conformance,
    register_inputs,
    verify_card,
)
from tools.coco80.sd_pack import HEADER_BYTES, INPUT_TENSOR_BYTES, build_input_shards, pack_input_tensor


def _fake_pack_input_image(source_image, destination, *, image_id, input_scale, input_zero_point):
    source = Path(source_image)
    source_sha = hashlib.sha256(source.read_bytes()).hexdigest()
    package = pack_input_tensor(
        bytes([image_id & 0x7F]) * INPUT_TENSOR_BYTES,
        destination,
        image_id=image_id,
        original_width=416,
        original_height=416,
        input_scale=input_scale,
        input_zero_point=input_zero_point,
        letterbox_scale=1.0,
        pad_x=0,
        pad_y=0,
        source_sha256=source_sha,
    )
    return {
        "image_id": image_id,
        "source_name": source.name,
        "source_sha256": source_sha,
        "letterbox": {
            "schema": "coco80.letterbox.v1",
            "source_width": 416,
            "source_height": 416,
            "model_width": 416,
            "model_height": 416,
            "resized_width": 416,
            "resized_height": 416,
            "scale": 1.0,
            "pad_left": 0,
            "pad_top": 0,
            "pad_right": 0,
            "pad_bottom": 0,
            "fill": 114,
            "pixel_format": "RGB",
            "resample": "PIL.BILINEAR",
        },
        "package": package.to_dict(),
    }


def _write_quant_manifest(path: Path, *, scale: float, zero_point: int) -> None:
    layers = [{"name": "m0", "quant": {"input": {
        "scale": scale, "zero_point": zero_point, "qmin": 0, "qmax": 127,
    }}}]
    layers.extend({"name": f"unused_{index}"} for index in range(1, 13))
    path.write_text(json.dumps({
        "format": "kv260-coco80-rtl-quantization",
        "version": 1,
        "layers": layers,
        "provenance": {"source_weights_sha256": "ab" * 32},
    }, indent=2, sort_keys=True) + "\n", encoding="utf-8")


class SdDeployTests(unittest.TestCase):
    def test_inputs_remain_provisional_until_quantization_matches(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "image.source"
            source.write_bytes(struct.pack("<I", 17))
            bit = root / "r5.bit"
            xsa = root / "r5.xsa"
            bit.write_bytes(b"bit")
            xsa.write_bytes(b"xsa")
            card = root / "COCO80_R5"
            prepare_card(card, bit=bit, xsa=xsa, source_root=root)
            with patch("tools.coco80.sd_pack.pack_input_image", _fake_pack_input_image):
                build_input_shards(
                    [(17, source)],
                    card / "INPUT",
                    input_scale=0.125,
                    input_zero_point=7,
                    expected_count=1,
                    shard_target_bytes=HEADER_BYTES + INPUT_TENSOR_BYTES,
                )
            input_manifest = card / "INPUT" / "input_index.json"

            provisional = register_inputs(card, input_manifest=input_manifest)
            self.assertEqual(provisional["status"], "INPUTS_PROVISIONAL")
            self.assertNotIn("quantization_binding", provisional)
            verified = verify_card(card)
            self.assertEqual(verified["card_status"], "INPUTS_PROVISIONAL")
            self.assertFalse(verified["runnable"])

            mismatch = root / "mismatch.json"
            _write_quant_manifest(mismatch, scale=0.25, zero_point=7)
            with self.assertRaisesRegex(RuntimeError, "differs from canonical"):
                register_inputs(
                    card,
                    input_manifest=input_manifest,
                    quantization_manifest=mismatch,
                )

            matching = root / "matching.json"
            _write_quant_manifest(matching, scale=0.125, zero_point=7)
            ready = register_inputs(
                card,
                input_manifest=input_manifest,
                quantization_manifest=matching,
            )
            self.assertEqual(ready["status"], "INPUTS_READY")
            self.assertEqual(ready["quantization_binding"]["input_zero_point"], 7)
            verified = verify_card(card)
            self.assertEqual(verified["card_status"], "INPUTS_READY")
            self.assertFalse(verified["runnable"])

    def test_conformance_selection_is_hash_bound_in_card_manifest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            card = root / "COCO80_R5"
            (card / "MANIFEST").mkdir(parents=True)
            (card / "INPUT").mkdir(parents=True)
            input_index = card / "INPUT" / "input_index.bin"
            input_index.write_bytes(b"index")
            (card / "MANIFEST" / "card_manifest.json").write_text(json.dumps({
                "format": "kv260-coco80-sd-card",
                "version": 1,
                "status": "DATA_READY",
                "input_index": {
                    "path": str(input_index.resolve()),
                    "bytes": input_index.stat().st_size,
                    "sha256": hashlib.sha256(input_index.read_bytes()).hexdigest(),
                },
            }), encoding="utf-8")
            manifest = root / "selection.json"
            index = root / "selection.bin"
            manifest.write_text("{}", encoding="utf-8")
            index.write_bytes(b"selection")
            manifest_sha = hashlib.sha256(manifest.read_bytes()).hexdigest()
            with patch(
                "tools.coco80.conformance.parse_conformance_binary",
                return_value={
                    "selection_manifest_sha256": manifest_sha,
                    "count": 128,
                    "input_index_crc32": 17,
                },
            ):
                registered = register_conformance(
                    card, selection_manifest=manifest, selection_index=index
                )
            self.assertEqual(registered["status"], "DATA_READY")
            self.assertEqual(registered["conformance_selection"]["count"], 128)
            self.assertEqual(verify_card(card)["checked_files"], 3)


if __name__ == "__main__":
    unittest.main()
